import Foundation
import Observation

/// Proxy Manager: shares this machine's VPN egress on the LAN (host side) and routes flagged
/// commands through a peer's share (client side).
///
/// One app covers both roles; a machine simply uses the side it needs:
/// - **Share** — supervise a `gost` listener and announce it over Bonjour.
/// - **Use** — browse the LAN, pick an active proxy, inject its env into flagged commands.
///
/// Deliberately thin: supervision is the EXISTING daemon engine (`ProcessManager.run` + watchdog +
/// orphan adoption + port-conflict panel) driven with a synthetic `Command`, and injection is the
/// existing `Command.env`. Genuinely new here is only Bonjour and this coordination.
///
/// Dependencies are injected behind protocols (probe pattern), so every path is unit-testable
/// without mDNS, the Keychain, or real processes.
@MainActor
@Observable
final class ProxyManager {
    @ObservationIgnored private let discovering: any ProxyDiscovering
    @ObservationIgnored private let advertiser: any ProxyAdvertising
    @ObservationIgnored private let credentials: any ProxyCredentialStore
    /// LAN IPv4 to announce. Injected so tests don't depend on the machine's real interfaces.
    @ObservationIgnored private let lanIP: () -> String?
    /// Resolves the installed `gost`. Injected so tests cover both "installed" and "missing".
    @ObservationIgnored private let gostPath: (ProxyShare) -> String?
    /// Asks the internet for our egress IP through the given proxy URL. Blocking → called off-main.
    @ObservationIgnored private let exitIPProbe: @Sendable (String) -> String?
    /// How many times to probe for the exit IP, and the pause between attempts. `gost` reports
    /// `.started` when the process is SPAWNED, so the first probe usually races its socket bind.
    @ObservationIgnored private let exitIPAttempts: Int
    @ObservationIgnored private let exitIPRetryDelay: Duration
    /// Maintains `~/.config/devdeck/proxy.env` for the `dp` shell helper.
    @ObservationIgnored private let envFile: any PrivateFileWriting
    /// Maintains the generated `gost.json` the listener is started with. Owner-only, because it
    /// holds the share password in plaintext — the command line no longer does.
    @ObservationIgnored private let shareConfigFile: any PrivateFileWriting
    /// Who is using our share, folded out of the listener's own output. Nothing outside this type
    /// reads it — views and tests go through `proxyClients` / `connectedClientCount` below.
    @ObservationIgnored private let clientMonitor: ProxyClientMonitor
    /// Last contents handed to `envFile`, so a browse update that changes nothing doesn't rewrite
    /// the file. nil means the file is absent as far as we know.
    @ObservationIgnored private var lastProxyEnvContents: String?
    /// Whether this instance has determined the file's state at least once. A stale file can survive
    /// a crash or an external edit of config.json, so the first refresh must act on disk rather than
    /// trust `lastProxyEnvContents`, which starts nil in every new instance. Set only once an
    /// operation has actually SUCCEEDED — after a failure we still don't know, so the next refresh
    /// must act on disk again.
    @ObservationIgnored private var proxyEnvStateDetermined = false
    /// Owned by `AppDelegate`; weak so the manager never keeps the app graph alive.
    @ObservationIgnored weak var store: CommandStore?
    @ObservationIgnored weak var processManager: ProcessManager?

    /// Proxies currently announced on the LAN (client side). Replaced wholesale on every browse update.
    private(set) var discovered: [DiscoveredProxy] = []
    /// The share is published on Bonjour right now.
    private(set) var isAdvertising = false
    /// `gost` isn't installed → the share can't start (the editor shows a warning).
    private(set) var gostMissing = false
    /// Our own egress IP as seen from the internet — proof traffic really leaves via the VPN.
    private(set) var lastExitIP: String?
    /// Cached "the active peer's credentials are on hand". Cached because SwiftUI bodies read it on
    /// every render and a Keychain lookup per render would be wasteful. Refreshed whenever the
    /// selection, the browse results, or the stored credentials change.
    private(set) var activeProxyHasCredentials = false

    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    /// Token of the in-flight exit-IP probe — a restart preempts an older, slower probe.
    @ObservationIgnored private var exitIPToken: UUID?
    @ObservationIgnored private var observingDaemonState = false
    @ObservationIgnored private var observingSettings = false

    init(
        discovering: any ProxyDiscovering = LiveProxyDiscovery(),
        advertiser: any ProxyAdvertising = LiveProxyAdvertiser(),
        credentials: any ProxyCredentialStore = KeychainProxyCredentialStore(),
        lanIP: @escaping () -> String? = { currentLANIPv4() },
        gostPath: @escaping (ProxyShare) -> String? = { $0.gostPath },
        exitIPProbe: @escaping @Sendable (String) -> String? = { proxyURL in
            ProcessTree.run("/usr/bin/curl", ["-s", "--max-time", "5", "-x", proxyURL, "https://api.ipify.org"])
        },
        exitIPAttempts: Int = 4,
        exitIPRetryDelay: Duration = .seconds(1),
        envFile: any PrivateFileWriting = LivePrivateFile(url: proxyEnvFileURL),
        shareConfigFile: any PrivateFileWriting = LivePrivateFile(url: ProxyShare.configURL),
        clientMonitor: ProxyClientMonitor = ProxyClientMonitor()
    ) {
        self.discovering = discovering
        self.advertiser = advertiser
        self.credentials = credentials
        self.lanIP = lanIP
        self.gostPath = gostPath
        self.exitIPProbe = exitIPProbe
        self.exitIPAttempts = exitIPAttempts
        self.exitIPRetryDelay = exitIPRetryDelay
        self.envFile = envFile
        self.shareConfigFile = shareConfigFile
        self.clientMonitor = clientMonitor
    }

    // MARK: - Lifecycle

    /// Called from `AppDelegate` once the store and process manager exist.
    func start() {
        observeSettings()
        refreshDerivedState()
        if store?.config.settings.proxyShareEnabled == true { startShare() }
        if store?.config.settings.proxyDiscoveryEnabled == true { startDiscovery() }
    }

    /// Re-arm an observation of the persisted settings — same pattern as `observeDaemonState`.
    ///
    /// `config.json` is hand-editable and the `FileWatcher` reloads it, but nothing told this
    /// manager. `routing(for:)` honours such an edit on the next launch, so hand-deselecting the
    /// active proxy left `proxy.env` still granting access — until the next browse update, which on
    /// a quiet network never comes. That is the one window where the terminal path and the in-app
    /// path genuinely disagreed, and it was fail-open.
    ///
    /// Cannot recurse: the refresh reads the store and writes the credential cache and the file,
    /// never the store.
    private func observeSettings() {
        guard let store, !observingSettings else { return }
        observingSettings = true
        withObservationTracking {
            _ = store.config.settings
        } onChange: { [weak self] in
            // onChange fires BEFORE the value is applied — read it back on the next main-actor hop.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observingSettings = false
                self.refreshDerivedState()
                self.observeSettings()
            }
        }
    }

    // MARK: - Share (host side)

    /// The active share config, or defaults when the store isn't wired yet.
    var share: ProxyShare { store?.config.proxy ?? ProxyShare() }

    /// Run state of the synthetic `gost` daemon (drives the popover row).
    var shareState: ProcessManager.RunState? { processManager?.states[ProxyShare.daemonID] }

    /// Build the synthetic daemon command. nil when `gost` isn't installed.
    ///
    /// The credentials are NOT here any more — they live in the config file this command points at,
    /// so the command string is safe to log and to show.
    func shareCommand() -> Command? {
        guard let path = gostPath(share) else { return nil }
        return share.toCommand(gostPath: path, configPath: shareConfigFile.url.path)
    }

    /// Write the config the listener is started with. False → do not start: `gost -C` on a missing
    /// file exits immediately, and starting anyway would just feed the watchdog a restart loop.
    private func writeShareConfig() -> Bool {
        let share = share
        let password = share.authEnabled ? credentials.password(for: ProxyCredentialAccount.share) : nil
        guard let json = share.gostConfigJSON(password: password) else { return false }
        return shareConfigFile.write(json)
    }

    /// Adopt a `gost` that survived a previous session, then start one if none is up.
    /// Supervision (watchdog restarts, port conflicts) is entirely the existing engine's job.
    func startShare() {
        guard let processManager else { return }
        guard let command = shareCommand() else {
            gostMissing = true
            DiagnosticLog.shared.log(
                "Proxy share: gost not found in \(ProxyShare.gostCandidates.joined(separator: ", "))", level: .warn)
            return
        }
        gostMissing = false
        // Before anything is launched: the listener reads its credentials from this file, and
        // rewriting it here is also what applies a password or port change on restart.
        guard writeShareConfig() else {
            DiagnosticLog.shared.log(
                "Proxy share: could not write \(shareConfigFile.url.path) — the listener was not started",
                level: .error)
            return
        }
        // Arm BEFORE anything can change the daemon's state, so the very first transition to
        // `daemonRunning` is what triggers the announcement — no matter who started the share
        // (launch, the Settings toggle, or the popover's play button).
        observeDaemonState()
        processManager.adoptSurvivingDaemons(commands: [ProxyShare.daemonID: command])
        switch processManager.states[ProxyShare.daemonID] {
        case .running, .daemonRunning:
            break   // already up (or adopted) — don't fight it over the port
        default:
            processManager.run(command)
        }
        // An ADOPTED listener is already `daemonRunning`, so no state change will fire —
        // announce it right here. Idempotent, so the normal start path isn't double-published.
        syncAdvertising()
    }

    /// Stop the listener, withdraw the announcement, and take the password back off the disk.
    ///
    /// The removal is last and unconditional: `stop` disarms the watchdog, so nothing is going to
    /// want this file again until the next explicit start, which rewrites it. (`gost` reads the
    /// config once at startup, so removing it never disturbs a listener that is already up.)
    ///
    /// Quitting the app does NOT come through here, so the file outlives a quit either way. That is
    /// a tidiness gap rather than an exposure — it is 0600, and the same password is in the
    /// Keychain regardless.
    func stopShare() {
        processManager?.stop(ProxyShare.daemonID)
        stopAdvertising()
        clientMonitor.clear()
        _ = shareConfigFile.remove()
    }

    /// Persist share settings; a live listener is restarted so port/auth changes take effect.
    func saveShare(_ updated: ProxyShare) {
        let wasRunning = shareState == .daemonRunning || shareState == .running
        store?.upsertProxyShare(updated)
        guard store?.config.settings.proxyShareEnabled == true else { return }
        if wasRunning {
            stopShare()
            startShare()
        }
    }

    func setShareEnabled(_ on: Bool) {
        store?.setProxyShareEnabled(on)
        if on { startShare() } else { stopShare() }
    }

    func sharePassword() -> String? { credentials.password(for: ProxyCredentialAccount.share) }

    func setSharePassword(_ password: String?) {
        credentials.setPassword(password, for: ProxyCredentialAccount.share)
    }

    // MARK: - Advertising (driven by the daemon's state)

    /// Re-arm an observation of the `gost` daemon's run state. Announcement follows the LISTENER,
    /// not the toggle: a watchdog restart re-publishes automatically, and a dead daemon is never
    /// advertised as reachable.
    private func observeDaemonState() {
        guard let processManager, !observingDaemonState else { return }
        observingDaemonState = true
        withObservationTracking {
            _ = processManager.states[ProxyShare.daemonID]
        } onChange: { [weak self] in
            // onChange fires BEFORE the value is applied — read it back on the next main-actor hop.
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observingDaemonState = false
                self.syncAdvertising()
                self.observeDaemonState()
            }
        }
    }

    private func syncAdvertising() {
        let up = processManager?.states[ProxyShare.daemonID] == .daemonRunning
        if up, store?.config.settings.proxyShareEnabled == true {
            startAdvertising()
        } else {
            stopAdvertising()
        }
    }

    private func startAdvertising() {
        guard !isAdvertising else { return }
        let share = share
        // Never announce the VPN tunnel address — peers can't reach it (see `pickLANIPv4`).
        guard let host = lanIP() else {
            DiagnosticLog.shared.log("Proxy share: no LAN IPv4 (en*) to announce — is Wi-Fi/Ethernet up?",
                                     level: .warn)
            return
        }
        let ad = ProxyAdvertisement(serviceName: share.effectiveServiceName, port: share.port,
                                    authRequired: share.authEnabled, host: host, exitIP: nil)
        advertiser.advertise(ad)
        isAdvertising = true
        // Guarded by `isAdvertising`, so this runs exactly once per bring-up of the listener —
        // including a watchdog restart, whose sessions all died with the previous process.
        clientMonitor.listenerDidStart()
        resolveExitIP(for: ad, share: share)
    }

    private func stopAdvertising() {
        exitIPToken = nil
        lastExitIP = nil
        guard isAdvertising else { return }
        advertiser.stop()
        isAdvertising = false
    }

    /// Ask the internet what IP our own proxy egresses from — best effort, off the main thread.
    /// A successful answer is folded into the TXT record so clients can see the tunnel is live.
    ///
    /// Retried, because the daemon reports `.started` when the process is SPAWNED: `gost` has not
    /// bound its socket yet, so the first attempt reliably gets connection-refused and returns
    /// nothing. Giving up is logged — a silent failure here looks exactly like "no VPN".
    private func resolveExitIP(for ad: ProxyAdvertisement, share: ProxyShare) {
        let password = share.authEnabled ? credentials.password(for: ProxyCredentialAccount.share) : nil
        let creds = (share.authEnabled && !share.username.isEmpty)
            ? "\(urlEscapeProxyCredential(share.username)):\(urlEscapeProxyCredential(password ?? ""))@"
            : ""
        let port = share.port
        let proxyURL = "http://\(creds)127.0.0.1:\(port)"
        let token = UUID()
        exitIPToken = token
        let probe = exitIPProbe
        let attempts = exitIPAttempts
        let delay = exitIPRetryDelay
        Task { @MainActor [weak self] in
            for attempt in 1...max(1, attempts) {
                let output = await Task.detached(priority: .utility) { probe(proxyURL) }.value
                let ip = output?.trimmingCharacters(in: .whitespacesAndNewlines)
                // A restart or a withdrawn announcement preempts an in-flight probe.
                guard let self, self.exitIPToken == token, self.isAdvertising else { return }
                if let ip, !ip.isEmpty {
                    self.lastExitIP = ip
                    var updated = ad
                    updated.exitIP = ip
                    self.advertiser.updateTXT(updated)
                    DiagnosticLog.shared.log("Proxy share exit IP: \(ip) (attempt \(attempt))")
                    return
                }
                if attempt < max(1, attempts) { try? await Task.sleep(for: delay) }
            }
            DiagnosticLog.shared.log(
                "Proxy share: could not resolve the exit IP through 127.0.0.1:\(port) — "
                    + "the proxy is announced, but the VPN egress is unconfirmed", level: .warn)
        }
    }

    // MARK: - Discovery (client side)

    /// The proxy chosen as active. Live Bonjour data wins; otherwise the last known endpoint is
    /// used, which is what keeps a flagged command working on networks that filter multicast
    /// (every corporate VPN) while leaving the proxy reachable over unicast TCP.
    ///
    /// Pure read: SwiftUI evaluates this during `body`, so it must never persist anything.
    var activeProxy: DiscoveredProxy? {
        guard let settings = store?.config.settings, let name = settings.activeProxyName else { return nil }
        if let live = discovered.first(where: { $0.name == name }) { return live }
        return rememberedProxy(named: name, settings: settings)
    }

    /// Rebuild the active proxy from the cached endpoint. Deliberately narrow — it resolves only when
    /// every condition below holds, and stays silent (nil → `.unavailable`) otherwise:
    ///
    /// - **discovery is on.** Switching it off is the user saying "stop using LAN proxies"; a
    ///   remembered address must not keep routing behind their back. This is the only path that
    ///   could still resolve then, since `stopDiscovery()` empties `discovered`.
    /// - **the endpoint is usable.** `config.json` is hand-editable, so mirror the wire parser's
    ///   guard rather than building `http://host:0`.
    /// - **we are back on the LAN it was learned on.** On a different Wi-Fi, `192.168.31.117:9999`
    ///   is a stranger's machine — and with `authRequired` cached we would send it the proxy
    ///   password unprompted. Unknown current LAN (no en* address) fails safe the same way.
    private func rememberedProxy(named name: String, settings: Settings) -> DiscoveredProxy? {
        guard settings.proxyDiscoveryEnabled else { return nil }
        guard let host = settings.activeProxyHost, !host.isEmpty,
              let port = settings.activeProxyPort, port > 0 else { return nil }
        guard let learnedOn = settings.activeProxyLANPrefix, learnedOn == currentLANPrefix else { return nil }
        return DiscoveredProxy(name: name, host: host, port: port,
                               authRequired: settings.activeProxyAuthRequired,
                               exitIP: nil, proto: "http+socks", schema: proxyTXTSchemaVersion,
                               isLive: false)
    }

    /// What the UI lists: everything currently announced, plus the active proxy when it is only
    /// remembered — otherwise a proxy that went quiet would vanish with no explanation.
    var visibleProxies: [DiscoveredProxy] {
        guard let active = activeProxy, !active.isLive else { return discovered }
        return discovered + [active]
    }

    /// Machines that have used this share recently (host side).
    var proxyClients: [ProxyClientMonitor.Client] { clientMonitor.clients }
    /// How many of them count as connected right now — what the popover shows.
    var connectedClientCount: Int { clientMonitor.activeCount }

    /// Feed the listener's own output to the connected-clients monitor, and nothing else's: any
    /// other daemon may legitimately print JSON that looks like a gost session.
    func ingestDaemonOutput(_ commandID: UUID, _ line: String) {
        guard commandID == ProxyShare.daemonID else { return }
        clientMonitor.ingest(line)
    }

    /// The active proxy needs credentials we don't have yet (the UI asks for a password).
    var activeProxyNeedsCredentials: Bool {
        guard let proxy = activeProxy, proxy.authRequired else { return false }
        return !activeProxyHasCredentials
    }

    func startDiscovery() {
        guard discoveryTask == nil else { return }
        let stream = discovering.results()
        discoveryTask = Task { @MainActor [weak self] in
            for await set in stream {
                guard let self else { return }
                self.discovered = set
                self.rememberActiveEndpointIfLive()
                self.refreshDerivedState()
            }
        }
        // Symmetry with `stopDiscovery()`: the remembered endpoint resolves the moment discovery is
        // back on, so the terminal path must not stay refusing until the first Bonjour callback.
        refreshDerivedState()
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discovering.stop()
        discovered = []
        refreshDerivedState()   // discovery off must stop the terminal path too
    }

    func setDiscoveryEnabled(_ on: Bool) {
        store?.setProxyDiscoveryEnabled(on)
        if on { startDiscovery() } else { stopDiscovery() }
    }

    /// Choose the active proxy. Switching to a DIFFERENT peer drops the stored username —
    /// credentials are per-peer, and silently reusing another host's login would just fail.
    func setActiveProxy(_ proxy: DiscoveredProxy?) {
        defer { refreshDerivedState() }
        guard let proxy else {
            store?.setActiveProxy(name: nil, username: nil)
            return
        }
        let sameAsBefore = store?.config.settings.activeProxyName == proxy.name
        store?.setActiveProxy(name: proxy.name,
                              username: sameAsBefore ? store?.config.settings.activeProxyUsername : nil)
        store?.rememberActiveProxyEndpoint(host: proxy.host, port: proxy.port,
                                           authRequired: proxy.authRequired, lanPrefix: currentLANPrefix)
    }

    /// The /24 this machine is on right now — the scope a remembered endpoint is valid within.
    /// nil when there is no LAN address at all, which makes every cached endpoint unusable (safe).
    private var currentLANPrefix: String? { lanIP().flatMap(lanPrefix(of:)) }

    func clientPassword(for proxyName: String) -> String? {
        credentials.password(for: ProxyCredentialAccount.client(proxyName))
    }

    /// Store the credentials for a discovered proxy: username in the config, password in the Keychain.
    func setClientCredentials(username: String, password: String?, for proxyName: String) {
        credentials.setPassword(password, for: ProxyCredentialAccount.client(proxyName))
        defer { refreshDerivedState() }
        guard store?.config.settings.activeProxyName == proxyName else { return }
        store?.setActiveProxy(name: proxyName, username: username.isEmpty ? nil : username)
    }

    /// One of the two places the endpoint cache is written (the other is `setActiveProxy`).
    /// No-op unless the active proxy is in the current result set — a remembered entry must not
    /// rewrite itself.
    private func rememberActiveEndpointIfLive() {
        guard let name = store?.config.settings.activeProxyName,
              let live = discovered.first(where: { $0.name == name }) else { return }
        store?.rememberActiveProxyEndpoint(host: live.host, port: live.port,
                                           authRequired: live.authRequired, lanPrefix: currentLANPrefix)
    }

    /// Re-read whether the active peer's credentials are complete — the only place that touches the
    /// Keychain for the UI's benefit.
    private func refreshCredentialCache() {
        guard let name = store?.config.settings.activeProxyName,
              let username = store?.config.settings.activeProxyUsername, !username.isEmpty,
              let password = clientPassword(for: name), !password.isEmpty else {
            activeProxyHasCredentials = false
            return
        }
        activeProxyHasCredentials = true
    }

    /// The active proxy resolved to something usable, or nil when a flagged command must fail.
    /// Shared by `routing(for:)` and the terminal helper's env file, so the two can never disagree
    /// about whether a proxy is usable.
    private func resolvedEndpoint() -> (proxy: DiscoveredProxy, user: String?, pass: String?)? {
        guard let proxy = activeProxy else { return nil }
        guard proxy.authRequired else { return (proxy, nil, nil) }
        guard let username = store?.config.settings.activeProxyUsername, !username.isEmpty,
              let password = clientPassword(for: proxy.name), !password.isEmpty else { return nil }
        return (proxy, username, password)
    }

    /// Keep `proxy.env` in step with the in-app verdict. Removing it is the safe state: without the
    /// file the `dp` helper refuses to run, which mirrors `.unavailable` failing a flagged command.
    ///
    /// Guarded against redundant writes: this runs on every Bonjour browse update, and an
    /// unconditional write would hit the disk several times a second on a live network.
    ///
    /// The cache advances ONLY on a reported success. A swallowed failure would be fail-open on the
    /// one control the design calls the safe state: we would believe a file that grants proxy access
    /// — and holds the password — was gone, and never try again.
    private func refreshProxyEnvFile() {
        guard let resolved = resolvedEndpoint(),
              let ip = lanIP(), let prefix = lanPrefix(of: ip) else {
            guard !proxyEnvStateDetermined || lastProxyEnvContents != nil else { return }
            guard envFile.remove() else { return }
            lastProxyEnvContents = nil
            proxyEnvStateDetermined = true
            return
        }
        let url = proxyURL(host: resolved.proxy.host, port: resolved.proxy.port,
                           user: resolved.user, pass: resolved.pass)
        let contents = proxyEnvFileContents(url: url, lanPrefix: prefix)
        guard contents != lastProxyEnvContents else { return }
        guard envFile.write(contents) else { return }
        lastProxyEnvContents = contents
        proxyEnvStateDetermined = true
    }

    /// Everything derived from the active choice, refreshed together so the two can't drift.
    private func refreshDerivedState() {
        refreshCredentialCache()
        refreshProxyEnvFile()
    }

    // MARK: - Routing (the ProcessManager hook)

    /// Resolve how a command should be launched. Wired into `ProcessManager.proxyRouting` by
    /// `AppDelegate`, so `ProcessManager` never learns this type exists.
    func routing(for command: Command) -> ProxyRouting {
        guard command.routeThroughProxy else { return .notRouted }
        guard let resolved = resolvedEndpoint() else { return .unavailable }
        // This whole feature exists because the original failure was invisible — so say it out loud
        // when a run leans on the cache. Logged HERE and not in `activeProxy`, which SwiftUI reads
        // on every render; `routing(for:)` runs once per launch.
        if !resolved.proxy.isLive {
            DiagnosticLog.shared.log(
                "Proxy routing “\(command.name)” through the remembered address of “\(resolved.proxy.name)” "
                    + "(\(resolved.proxy.host):\(resolved.proxy.port)) — it is not announced on the LAN right now")
        }
        return .routed(env: proxyEnv(host: resolved.proxy.host, port: resolved.proxy.port,
                                     user: resolved.user, pass: resolved.pass))
    }
}
