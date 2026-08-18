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
    /// Maintains the generated `proxy-bridge.json` the remote proxy's bridge is started with.
    /// No secrets inside — owner-only purely for consistency with its siblings.
    @ObservationIgnored private let bridgeConfigFile: any PrivateFileWriting
    /// Launches the proxied Chrome instance. Injected so tests record the argument vector.
    @ObservationIgnored private let browserLauncher: @MainActor ([String]) -> Bool
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

    /// Client-side check verdict — one probe through the active proxy, driven by the popover button.
    enum ClientCheck: Equatable {
        case idle
        case running
        /// The egress IP the internet reported through the proxy — the check's proof.
        case success(String)
        case failed
    }

    /// What the popover's check row shows. Reset whenever the active proxy changes — a green check
    /// for one proxy must not survive onto another.
    private(set) var clientCheck: ClientCheck = .idle

    @ObservationIgnored private var discoveryTask: Task<Void, Never>?
    /// Token of the in-flight exit-IP probe — a restart preempts an older, slower probe.
    @ObservationIgnored private var exitIPToken: UUID?
    /// Same preemption for the client-side check: a proxy switch must orphan a probe still out.
    @ObservationIgnored private var clientCheckToken: UUID?
    @ObservationIgnored private var observingDaemonState = false
    @ObservationIgnored private var observingRemoteState = false
    @ObservationIgnored private var observingSettings = false
    /// Mirrors the daemon's own `.daemonRunning` state, independent of `isAdvertising` — see
    /// `syncAdvertising()`. Edges drive `clientMonitor.listenerDidStart()` / `listenerDidStop()`.
    @ObservationIgnored private var listenerUp = false

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
        bridgeConfigFile: any PrivateFileWriting = LivePrivateFile(url: RemoteProxy.bridgeConfigURL),
        browserLauncher: @escaping @MainActor ([String]) -> Bool = { launchProxyBrowser(arguments: $0) },
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
        self.bridgeConfigFile = bridgeConfigFile
        self.browserLauncher = browserLauncher
        self.clientMonitor = clientMonitor
    }

    // MARK: - Lifecycle

    /// Called from `AppDelegate` once the store and process manager exist.
    func start() {
        observeSettings()
        refreshDerivedState()
        if store?.config.settings.proxyShareEnabled == true { startShare() }
        if store?.config.settings.proxyDiscoveryEnabled == true { startDiscovery() }
        if activeRemoteProxy != nil { startRemote() }
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

    /// Build the synthetic daemon command. nil only for the gost engine without an installed
    /// binary — the built-in engine always resolves.
    ///
    /// The credentials are NOT here any more — they live in the config file this command points at,
    /// so the command string is safe to log and to show.
    func shareCommand() -> Command? {
        share.toCommand(gostPath: gostPath(share), configPath: shareConfigFile.url.path)
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

    // MARK: - Remote proxy (client side, over SSH)

    /// The remote (SSH) proxy chosen as active, or nil. Pure read — SwiftUI evaluates it in `body`.
    var activeRemoteProxy: RemoteProxy? {
        guard let id = store?.config.settings.activeRemoteProxyID else { return nil }
        return store?.config.remoteProxies.first { $0.id == id }
    }

    /// Both halves of the remote route are alive: the ssh tunnel AND the local bridge.
    /// This is the ONLY definition of "usable" for the remote kind — the endpoint is loopback,
    /// so reachability says nothing; process state is everything.
    private func remoteDaemonsRunning(_ remote: RemoteProxy) -> Bool {
        guard let tunnelID = remote.tunnelCommandID, let processManager else { return false }
        return processManager.states[tunnelID] == .daemonRunning
            && processManager.states[RemoteProxy.bridgeDaemonID] == .daemonRunning
    }

    /// The remote proxy as the rest of the client side sees it — the same shape a Bonjour find
    /// has, so `routing`, the check button and the URL builder are reused verbatim.
    private func syntheticProxy(for remote: RemoteProxy) -> DiscoveredProxy {
        DiscoveredProxy(name: remote.name, host: "127.0.0.1", port: remote.localPort,
                        authRequired: false, exitIP: nil, proto: "http",
                        schema: proxyTXTSchemaVersion, isLive: remoteDaemonsRunning(remote))
    }

    /// Create a remote proxy AND its tunnel command in one step. The command is a regular,
    /// visible, user-editable daemon from this moment on; only its id is remembered here.
    func addRemoteProxy(name: String, destination: String, localPort: Int, socksPort: Int) {
        var remote = RemoteProxy(name: name, localPort: localPort, socksPort: socksPort)
        let tunnel = remote.makeTunnelCommand(destination: destination)
        remote.tunnelCommandID = tunnel.id
        store?.upsert(tunnel)
        store?.upsertRemoteProxy(remote)
    }

    /// Choose (or clear) the active remote proxy — the mirror of `setActiveProxy`.
    func setActiveRemoteProxy(_ remote: RemoteProxy?) {
        clientCheckToken = nil
        clientCheck = .idle
        defer { refreshDerivedState() }
        guard let remote else {
            store?.setActiveRemoteProxy(id: nil)
            stopRemote()
            return
        }
        store?.setActiveRemoteProxy(id: remote.id)
        startRemote()
    }

    /// Save edits to a remote proxy; a live pair is restarted so a port change takes effect.
    func saveRemoteProxy(_ updated: RemoteProxy) {
        let wasActive = store?.config.settings.activeRemoteProxyID == updated.id
        store?.upsertRemoteProxy(updated)
        guard wasActive else { return }
        stopRemote()
        startRemote()
    }

    /// Delete a remote proxy (and optionally its tunnel command). The store clears the selection;
    /// the daemons must not outlive it.
    func deleteRemoteProxy(_ remote: RemoteProxy, alsoTunnelCommand: Bool) {
        if store?.config.settings.activeRemoteProxyID == remote.id { stopRemote() }
        store?.deleteRemoteProxy(id: remote.id)
        if alsoTunnelCommand, let tunnelID = remote.tunnelCommandID {
            store?.delete(commandID: tunnelID)
        }
        refreshDerivedState()
    }

    /// Bring the pair up: config first (the bridge reads it at start), then both daemons.
    /// Mirror of `startShare` — already-running daemons are left alone, not fought over the port.
    private func startRemote() {
        guard let processManager, let remote = activeRemoteProxy else { return }
        guard let tunnelID = remote.tunnelCommandID,
              let tunnel = store?.commandsByID[tunnelID] else {
            DiagnosticLog.shared.log(
                "Remote proxy “\(remote.name)”: no tunnel command linked — nothing started", level: .warn)
            return
        }
        guard let json = bridgeConfigJSON(localPort: remote.localPort, socksPort: remote.socksPort),
              bridgeConfigFile.write(json) else {
            DiagnosticLog.shared.log(
                "Remote proxy: could not write \(bridgeConfigFile.url.path) — nothing started",
                level: .error)
            return
        }
        observeRemoteDaemonState()
        for command in [tunnel, remote.bridgeCommand(configPath: bridgeConfigFile.url.path)] {
            switch processManager.states[command.id] {
            case .running, .daemonRunning: break
            default: processManager.run(command)
            }
        }
    }

    /// Stop the pair and take the generated config back off the disk. Mirror of `stopShare`.
    private func stopRemote() {
        if let tunnelID = store?.config.remoteProxies
            .first(where: { $0.id == store?.config.settings.activeRemoteProxyID })?.tunnelCommandID {
            processManager?.stop(tunnelID)
        } else {
            // The selection may already be cleared (deselect clears first) — stop every linked
            // tunnel that is up rather than leaving an orphan behind.
            for remote in store?.config.remoteProxies ?? [] {
                if let id = remote.tunnelCommandID,
                   processManager?.states[id] == .daemonRunning || processManager?.states[id] == .running {
                    processManager?.stop(id)
                }
            }
        }
        processManager?.stop(RemoteProxy.bridgeDaemonID)
        _ = bridgeConfigFile.remove()
    }

    /// Re-arm an observation of the remote pair's run states — the same pattern as
    /// `observeDaemonState`. What hangs off it is `proxy.env`: the file must appear when the
    /// tunnel finishes coming up (seconds after selection) and vanish when either half dies.
    private func observeRemoteDaemonState() {
        guard let processManager, !observingRemoteState else { return }
        observingRemoteState = true
        let tunnelID = activeRemoteProxy?.tunnelCommandID
        withObservationTracking {
            _ = processManager.states[RemoteProxy.bridgeDaemonID]
            if let tunnelID { _ = processManager.states[tunnelID] }
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.observingRemoteState = false
                self.refreshDerivedState()
                // Keep observing while a remote proxy is still the active choice.
                if self.activeRemoteProxy != nil { self.observeRemoteDaemonState() }
            }
        }
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
        // The monitor's bring-up/tear-down belongs to the LISTENER's own state, not to whether
        // Bonjour ends up announcing it. Both diverge from `up`: `startAdvertising()` below also
        // bails out with no LAN address, and advertising is withdrawn whenever the share toggle is
        // off even though a still-running `gost` keeps logging real sessions. `listenerUp` mirrors
        // `up` alone, so a listener with no LAN address still gets its sweep armed and a listener
        // the watchdog gives up on still gets its dangling sessions zeroed.
        if up != listenerUp {
            listenerUp = up
            if up {
                // Idempotent per bring-up (including a watchdog restart) via the `listenerUp`
                // guard above — sessions all died with whatever ran before, but the machines
                // themselves stay listed.
                clientMonitor.listenerDidStart()
            } else {
                // The listener is not merely unannounced — it is gone. Its live sessions die with
                // it; the machine list itself is untouched (only an explicit `stopShare()` clears
                // that, via `clear()`).
                clientMonitor.listenerDidStop()
            }
        }
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
        var ad = ProxyAdvertisement(serviceName: share.effectiveServiceName, port: share.port,
                                    authRequired: share.authEnabled, host: host, exitIP: nil)
        ad.proto = share.engine == .builtIn ? "http" : "http+socks"
        advertiser.advertise(ad)
        isAdvertising = true
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
        // The remote kind first — the two selections are mutually exclusive by construction.
        if let remote = activeRemoteProxy { return syntheticProxy(for: remote) }
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

    // MARK: - Proxied browser

    /// The browser button's enablement: exactly what a launch would use.
    var canOpenProxyBrowser: Bool { resolvedEndpoint() != nil }

    /// Open the separate proxied Chrome instance pointed at the ACTIVE proxy — the browser half
    /// of an OAuth login (`/login` in Claude Code). Same resolution as `routing(for:)`, so the
    /// browser egresses exactly where a flagged command would.
    ///
    /// Returns false ONLY when a launch was attempted and Chrome was missing (the UI reports it);
    /// true when it launched, and true when there was nothing to launch (the button is disabled
    /// in that state anyway, so "no proxy" is not an error to surface).
    @discardableResult
    func openProxyBrowser() -> Bool {
        guard let resolved = resolvedEndpoint() else { return true }
        let url = proxyURL(host: resolved.proxy.host, port: resolved.proxy.port,
                           user: resolved.user, pass: resolved.pass)
        return browserLauncher(proxyBrowserArguments(proxyURL: url, profileDir: proxyBrowserProfileURL.path))
    }

    /// One probe through the ACTIVE proxy from THIS machine — the popover's check button.
    /// Deliberately the same resolution as `routing(for:)` (endpoint, credentials, URL builder),
    /// so a green check proves exactly what a flagged command will get. One attempt: unlike the
    /// host-side probe there is no just-spawned gost to wait out, and the button is a retry.
    func checkActiveProxy() {
        guard let resolved = resolvedEndpoint() else {
            clientCheckToken = nil
            clientCheck = .idle
            return
        }
        let url = proxyURL(host: resolved.proxy.host, port: resolved.proxy.port,
                           user: resolved.user, pass: resolved.pass)
        let token = UUID()
        clientCheckToken = token
        clientCheck = .running
        let probe = exitIPProbe
        Task { @MainActor [weak self] in
            let output = await Task.detached(priority: .utility) { probe(url) }.value
            guard let self, self.clientCheckToken == token else { return }
            let ip = output?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.clientCheck = ip.isEmpty ? .failed : .success(ip)
        }
    }

    /// Choose the active proxy. Switching to a DIFFERENT peer drops the stored username —
    /// credentials are per-peer, and silently reusing another host's login would just fail.
    func setActiveProxy(_ proxy: DiscoveredProxy?) {
        clientCheckToken = nil
        clientCheck = .idle
        defer { refreshDerivedState() }
        guard let proxy else {
            store?.setActiveProxy(name: nil, username: nil)
            return
        }
        // Choosing a discovered proxy displaces a remote one — its daemons must not keep running
        // for a selection that no longer exists. Stop BEFORE the store clears the id (stopRemote
        // resolves the tunnel command through the still-current selection).
        if store?.config.settings.activeRemoteProxyID != nil { stopRemote() }
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
        // Remote kind: the endpoint is loopback, so reachability proves nothing — usable means
        // BOTH halves of the route (tunnel + bridge) are alive, and nothing less.
        if let remote = activeRemoteProxy {
            guard remoteDaemonsRunning(remote) else { return nil }
            return (syntheticProxy(for: remote), nil, nil)
        }
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
        // A remote proxy's loopback endpoint is valid on any network — the tunnel is the scope,
        // so the helper gets the `*` wildcard and no LAN address is required at all.
        let scope = activeRemoteProxy != nil ? "*" : lanIP().flatMap(lanPrefix(of:))
        guard let resolved = resolvedEndpoint(), let prefix = scope else {
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
