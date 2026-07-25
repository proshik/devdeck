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
        exitIPRetryDelay: Duration = .seconds(1)
    ) {
        self.discovering = discovering
        self.advertiser = advertiser
        self.credentials = credentials
        self.lanIP = lanIP
        self.gostPath = gostPath
        self.exitIPProbe = exitIPProbe
        self.exitIPAttempts = exitIPAttempts
        self.exitIPRetryDelay = exitIPRetryDelay
    }

    // MARK: - Lifecycle

    /// Called from `AppDelegate` once the store and process manager exist.
    func start() {
        refreshCredentialCache()
        if store?.config.settings.proxyShareEnabled == true { startShare() }
        if store?.config.settings.proxyDiscoveryEnabled == true { startDiscovery() }
    }

    // MARK: - Share (host side)

    /// The active share config, or defaults when the store isn't wired yet.
    var share: ProxyShare { store?.config.proxy ?? ProxyShare() }

    /// Run state of the synthetic `gost` daemon (drives the popover row).
    var shareState: ProcessManager.RunState? { processManager?.states[ProxyShare.daemonID] }

    /// Build the synthetic daemon command, pulling the password from the Keychain.
    /// nil when `gost` isn't installed.
    func shareCommand() -> Command? {
        let share = share
        guard let path = gostPath(share) else { return nil }
        let password = share.authEnabled ? credentials.password(for: ProxyCredentialAccount.share) : nil
        return share.toCommand(gostPath: path, password: password)
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

    /// Stop the listener and withdraw the announcement.
    func stopShare() {
        processManager?.stop(ProxyShare.daemonID)
        stopAdvertising()
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

    /// The proxy chosen as active, resolved by Bonjour NAME against the current results.
    /// nil when nothing is selected or the selected peer is currently offline.
    var activeProxy: DiscoveredProxy? {
        guard let name = store?.config.settings.activeProxyName else { return nil }
        return discovered.first { $0.name == name }
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
                self.refreshCredentialCache()
            }
        }
    }

    func stopDiscovery() {
        discoveryTask?.cancel()
        discoveryTask = nil
        discovering.stop()
        discovered = []
    }

    func setDiscoveryEnabled(_ on: Bool) {
        store?.setProxyDiscoveryEnabled(on)
        if on { startDiscovery() } else { stopDiscovery() }
    }

    /// Choose the active proxy. Switching to a DIFFERENT peer drops the stored username —
    /// credentials are per-peer, and silently reusing another host's login would just fail.
    func setActiveProxy(_ proxy: DiscoveredProxy?) {
        defer { refreshCredentialCache() }
        guard let proxy else {
            store?.setActiveProxy(name: nil, username: nil)
            return
        }
        let sameAsBefore = store?.config.settings.activeProxyName == proxy.name
        store?.setActiveProxy(name: proxy.name,
                              username: sameAsBefore ? store?.config.settings.activeProxyUsername : nil)
    }

    func clientPassword(for proxyName: String) -> String? {
        credentials.password(for: ProxyCredentialAccount.client(proxyName))
    }

    /// Store the credentials for a discovered proxy: username in the config, password in the Keychain.
    func setClientCredentials(username: String, password: String?, for proxyName: String) {
        credentials.setPassword(password, for: ProxyCredentialAccount.client(proxyName))
        defer { refreshCredentialCache() }
        guard store?.config.settings.activeProxyName == proxyName else { return }
        store?.setActiveProxy(name: proxyName, username: username.isEmpty ? nil : username)
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

    // MARK: - Routing (the ProcessManager hook)

    /// Resolve how a command should be launched. Wired into `ProcessManager.proxyRouting` by
    /// `AppDelegate`, so `ProcessManager` never learns this type exists.
    func routing(for command: Command) -> ProxyRouting {
        guard command.routeThroughProxy else { return .notRouted }
        guard let proxy = activeProxy else { return .unavailable }
        guard proxy.authRequired else {
            return .routed(env: proxyEnv(host: proxy.host, port: proxy.port, user: nil, pass: nil))
        }
        guard let username = store?.config.settings.activeProxyUsername, !username.isEmpty,
              let password = clientPassword(for: proxy.name), !password.isEmpty else { return .unavailable }
        return .routed(env: proxyEnv(host: proxy.host, port: proxy.port, user: username, pass: password))
    }
}
