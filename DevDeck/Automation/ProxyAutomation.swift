import Foundation

/// `DevDeck automation proxy …`. No proxy logic of its own: selection, the remote tunnel and
/// bridge, the check and the share are `ProxyManager`'s — the same calls the popover and the Proxy
/// page make — and the daemons stay under `ProcessManager`'s supervision. This type only checks
/// access, refuses what needs a person (credentials), waits for the outcome and words the answer.
///
/// Passwords never pass through here, in either direction: the answer says only whether one is saved.
@MainActor
final class ProxyAutomation {
    private let proxy: ProxyManager
    private let config: () -> Config
    private let startWait: Duration
    private let checkWait: Duration
    private let stopWait: Duration
    private let pollInterval: Duration

    init(proxy: ProxyManager, config: @escaping () -> Config,
         startWait: Duration = .seconds(AutomationLimits.proxyStartWaitSeconds),
         checkWait: Duration = .seconds(AutomationLimits.proxyCheckWaitSeconds),
         stopWait: Duration = .seconds(AutomationLimits.stopWaitSeconds),
         pollInterval: Duration = .milliseconds(50)) {
        self.proxy = proxy
        self.config = config
        self.startWait = startWait
        self.checkWait = checkWait
        self.stopWait = stopWait
        self.pollInterval = pollInterval
    }

    func handle(_ request: AutomationProxyRequest) async -> AutomationResponse {
        // The client validates too; a hand-made socket request is checked again here.
        if let problem = Self.invalid(request) { return AutomationFields.usage(problem) }
        do {
            let settings = config().settings
            guard settings.automationEnabled else { throw AutomationRefusal.automationDisabled }
            guard settings.automationProxyEnabled else { throw AutomationRefusal.proxyAutomationDisabled }
            switch request.action {
            case .list: return list()
            case .status: return AutomationFields.response([clientBlock(), shareBlock()])
            case .use: return try await use(request.target ?? "")
            case .check: return try await check()
            case .shareOn: return try await shareOn()
            case .shareOff: return try await shareOff()
            case .shareStatus: return AutomationFields.response([shareBlock()])
            case .shareSet: return try await shareSet(request)
            }
        } catch {
            return AutomationFields.refusal(error)
        }
    }

    private static func invalid(_ request: AutomationProxyRequest) -> String? {
        switch request.action {
        case .use:
            guard let target = request.target, !target.trimmingCharacters(in: .whitespaces).isEmpty else {
                return L10n.automationUsageMissingProxy
            }
        case .shareSet:
            guard request.setsShareField else { return L10n.automationUsageNoShareField }
            if let port = request.port, !AutomationProxyRequest.validPorts.contains(port) {
                return L10n.automationUsageBadPort(String(port))
            }
        default:
            break
        }
        return nil
    }

    private var processManager: ProcessManager? { proxy.processManager }

    // MARK: list / status

    private func list() -> AutomationResponse {
        let config = config()
        let settings = config.settings
        var blocks: [AutomationFields] = []
        for found in proxy.visibleProxies {
            var fields = AutomationFields()
            fields.add("name", found.name)
            fields.add("type", "lan")
            fields.add("live", yes: found.isLive)
            fields.add("auth", yes: found.authRequired)
            fields.add("active", yes: settings.activeRemoteProxyID == nil && settings.activeProxyName == found.name)
            fields.add("endpoint", Self.endpoint(found.host, found.port))
            fields.add("exitIP", found.exitIP)
            blocks.append(fields)
        }
        for remote in config.remoteProxies {
            let active = settings.activeRemoteProxyID == remote.id
            var fields = AutomationFields()
            fields.add("name", remote.name)
            fields.add("type", "remote")
            fields.add("id", remote.id.uuidString)
            fields.add("live", yes: active && proxy.activeProxy?.isLive == true)
            fields.add("auth", yes: false)
            fields.add("active", yes: active)
            fields.add("endpoint", Self.endpoint("127.0.0.1", remote.localPort))
            if tunnel(of: remote) == nil { fields.add("tunnel", "missing") }
            blocks.append(fields)
        }
        guard !blocks.isEmpty else {
            return AutomationResponse(exitCode: AutomationExitCode.success, stdout: "",
                                      stderr: L10n.automationProxyListEmpty(discoveryOn: settings.proxyDiscoveryEnabled))
        }
        return AutomationFields.response(blocks)
    }

    /// The client side: what is chosen and whether a flagged command would get through it now.
    private func clientBlock(message override: String? = nil) -> AutomationFields {
        let config = config()
        let settings = config.settings
        var fields = AutomationFields()
        var message: String
        if let remote = proxy.activeRemoteProxy {
            let usable = proxy.activeProxyUsable
            fields.add("proxy", remote.name)
            fields.add("type", "remote")
            fields.add("id", remote.id.uuidString)
            fields.add("endpoint", Self.endpoint("127.0.0.1", remote.localPort))
            fields.add("live", yes: usable)
            fields.add("usable", yes: usable)
            fields.add("tunnel", tunnel(of: remote).map { AutomationService.describe(processManager?.states[$0.id]) } ?? "missing")
            fields.add("bridge", AutomationService.describe(processManager?.states[RemoteProxy.bridgeDaemonID]))
            message = usable ? L10n.automationProxyUsable(remote.name) : L10n.automationProxyNotUsable(remote.name)
        } else if let active = proxy.activeProxy {
            let usable = proxy.activeProxyUsable
            fields.add("proxy", active.name)
            fields.add("type", "lan")
            fields.add("endpoint", Self.endpoint(active.host, active.port))
            fields.add("live", yes: active.isLive)
            fields.add("usable", yes: usable)
            fields.add("auth", yes: active.authRequired)
            if active.authRequired { fields.add("credentials", proxy.activeProxyNeedsCredentials ? "missing" : "saved") }
            fields.add("exitIP", active.exitIP)
            message = !usable && active.authRequired && proxy.activeProxyNeedsCredentials
                ? L10n.automationProxyCredentialsMissing(active.name)
                : usable ? L10n.automationProxyUsable(active.name) : L10n.automationProxyNotUsable(active.name)
        } else if let name = settings.activeProxyName {
            // Chosen, but neither announced nor remembered for this network (or discovery is off).
            fields.add("proxy", name)
            fields.add("type", "lan")
            fields.add("live", yes: false)
            fields.add("usable", yes: false)
            message = L10n.automationProxyNotUsable(name)
        } else {
            fields.add("proxy", AutomationProxyRequest.noneTarget)
            fields.add("usable", yes: false)
            message = L10n.automationProxyNone
        }
        fields.add("discovery", settings.proxyDiscoveryEnabled ? "on" : "off")
        fields.add("message", override ?? message)
        return fields
    }

    /// The host side: this Mac's share.
    private func shareBlock(restarted: Bool? = nil, message override: String? = nil,
                            output: Bool = false) -> AutomationFields {
        let config = config()
        let share = config.proxy
        let enabled = config.settings.proxyShareEnabled
        let state = proxy.shareState
        let conflict = processManager?.portConflicts[ProxyShare.daemonID]
        var fields = AutomationFields()
        fields.add("share", enabled ? "on" : "off")
        fields.add("state", AutomationService.describe(state))
        fields.add("engine", share.engine.rawValue)
        fields.add("port", share.port)
        fields.add("serviceName", share.effectiveServiceName)
        fields.add("auth", share.authEnabled ? "on" : "off")
        if share.authEnabled {
            fields.add("username", share.username)
            fields.add("password", proxy.sharePassword()?.isEmpty == false ? "saved" : "missing")
        }
        fields.add("advertising", yes: proxy.isAdvertising)
        fields.add("exitIP", proxy.lastExitIP)
        fields.add("clients", proxy.connectedClientCount)
        fields.add("restarted", yes: restarted)
        if let conflict { fields.add("portOwner", "\(conflict.occupant.processName) (PID \(conflict.occupant.pid))") }
        let message: String
        if let conflict {
            message = L10n.automationSharePortOccupied(conflict.port, conflict.occupant.processName, conflict.occupant.pid)
        } else {
            switch state {
            case .daemonRunning?: message = L10n.automationShareUp(share.port)
            case .running?: message = L10n.automationShareStarting
            case .failed(let code)?: message = L10n.automationShareFailed(code)
            default: message = enabled ? L10n.automationShareNotRunning : L10n.automationShareOff
            }
        }
        fields.add("message", override ?? message)
        if output { fields.addOutput(AutomationFields.tail(processManager?.logs[ProxyShare.daemonID])) }
        return fields
    }

    // MARK: use

    private enum Choice {
        case lan(DiscoveredProxy)
        case remote(RemoteProxy)
    }

    private func use(_ target: String) async throws -> AutomationResponse {
        if target == AutomationProxyRequest.noneTarget {
            let settings = config().settings
            if settings.activeRemoteProxyID != nil { proxy.setActiveRemoteProxy(nil) }
            if settings.activeProxyName != nil { proxy.setActiveProxy(nil) }
            return AutomationFields.response([clientBlock(message: L10n.automationProxyCleared)])
        }
        switch try resolve(target) {
        case .lan(let found):
            // Only a person can enter a password; a selection that cannot route is refused unchanged.
            if found.authRequired, !credentialsSaved(for: found.name) {
                throw AutomationRefusal.proxyCredentialsMissing(found.name)
            }
            proxy.setActiveProxy(found)
            return AutomationFields.response([clientBlock()])
        case .remote(let remote):
            guard let tunnel = tunnel(of: remote) else { throw AutomationRefusal.remoteTunnelMissing(remote.name) }
            proxy.setActiveRemoteProxy(remote)
            return try await awaitRemote(remote, tunnelID: tunnel.id)
        }
    }

    /// A name among the LAN proxies the UI lists and the remote proxies, or a remote proxy's UUID.
    private func resolve(_ query: String) throws -> Choice {
        let config = config()
        let lan = proxy.visibleProxies.filter { $0.name == query }.map(Choice.lan)
        let remote: [Choice]
        if let id = UUID(uuidString: query.trimmingCharacters(in: .whitespaces)),
           let match = config.remoteProxies.first(where: { $0.id == id }) {
            remote = [.remote(match)]
        } else {
            remote = config.remoteProxies.filter { $0.name == query }.map(Choice.remote)
        }
        let matches = lan + remote
        switch matches.count {
        case 0:
            let all = proxy.visibleProxies.map(Choice.lan) + config.remoteProxies.map(Choice.remote)
            throw AutomationRefusal.unknownProxy(query, all.map(Self.listing),
                                                 discoveryOn: config.settings.proxyDiscoveryEnabled)
        case 1: return matches[0]
        default: throw AutomationRefusal.ambiguousProxy(query, matches.map(Self.listing))
        }
    }

    /// The username lives in the config only for the current choice (`setActiveProxy` drops it
    /// on a switch), the password in the Keychain per proxy — both are needed to route.
    private func credentialsSaved(for name: String) -> Bool {
        let settings = config().settings
        guard settings.activeRemoteProxyID == nil, settings.activeProxyName == name,
              let username = settings.activeProxyUsername, !username.isEmpty else { return false }
        return proxy.clientPassword(for: name)?.isEmpty == false
    }

    /// Wait for the tunnel and the bridge `setActiveRemoteProxy` started (or left running).
    private func awaitRemote(_ remote: RemoteProxy, tunnelID: UUID) async throws -> AutomationResponse {
        let ids = [tunnelID, RemoteProxy.bridgeDaemonID]
        let deadline = ContinuousClock.now + startWait
        while true {
            guard config().settings.activeRemoteProxyID == remote.id else {
                // Someone chose another proxy meanwhile; report what is selected now.
                return AutomationFields.response([clientBlock(message: L10n.automationProxySelectionChanged)],
                                                 code: AutomationExitCode.failed)
            }
            let states = ids.map { processManager?.states[$0] }
            if let conflict = ids.lazy.compactMap({ self.processManager?.portConflicts[$0] }).first {
                var fields = clientBlock(message: L10n.automationRemotePortOccupied(
                    remote.name, conflict.port, conflict.occupant.processName, conflict.occupant.pid))
                fields.add("port", conflict.port)
                fields.add("portOwner", "\(conflict.occupant.processName) (PID \(conflict.occupant.pid))")
                return AutomationFields.response([fields], code: AutomationExitCode.failed)
            }
            if states.allSatisfy({ $0 == .daemonRunning }) {
                return AutomationFields.response([clientBlock()])
            }
            if states.contains(where: Self.isFailed) {
                var fields = clientBlock(message: L10n.automationRemoteFailed(remote.name))
                fields.addOutput(AutomationFields.tail(processManager?.logs[tunnelID]))
                return AutomationFields.response([fields], code: AutomationExitCode.failed)
            }
            if ContinuousClock.now >= deadline {
                let seconds = Int(startWait.components.seconds)
                return AutomationFields.response([clientBlock(message: L10n.automationRemoteTimedOut(remote.name, seconds))],
                                                 code: AutomationExitCode.timedOut)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    // MARK: check

    private func check() async throws -> AutomationResponse {
        let name = proxy.activeProxy?.name
        proxy.checkActiveProxy()
        if case .unavailable(let reason) = proxy.clientCheck { throw AutomationRefusal.proxyCheckUnavailable(reason) }
        let deadline = ContinuousClock.now + checkWait
        while proxy.clientCheck == .running, ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
        }
        var fields = AutomationFields()
        let code: Int32
        switch proxy.clientCheck {
        case .success(let ip):
            fields.add("status", "ok")
            fields.add("proxy", name)
            fields.add("exitIP", ip)
            fields.add("message", L10n.automationProxyCheckOK(name ?? "", ip))
            code = AutomationExitCode.success
        case .running:
            fields.add("status", "timedOut")
            fields.add("proxy", name)
            fields.add("message", L10n.automationProxyCheckTimedOut(Int(checkWait.components.seconds)))
            code = AutomationExitCode.timedOut
        case .unavailable(let reason):
            throw AutomationRefusal.proxyCheckUnavailable(reason)
        case .failed, .idle:
            // `.idle`: the selection changed while the probe was out, which orphans it.
            fields.add("status", "failed")
            fields.add("proxy", name)
            fields.add("message", proxy.clientCheck == .idle ? L10n.automationProxySelectionChanged
                                                             : L10n.automationProxyCheckFailed(name ?? ""))
            code = AutomationExitCode.failed
        }
        return AutomationFields.response([fields], code: code)
    }

    // MARK: share

    private var shareIsUp: Bool { proxy.shareState == .running || proxy.shareState == .daemonRunning }

    private func shareOn() async throws -> AutomationResponse {
        if config().settings.proxyShareEnabled, proxy.shareState == .daemonRunning {
            return AutomationFields.response([shareBlock(message: L10n.automationShareAlreadyOn(config().proxy.port))])
        }
        try requireStartable(config().proxy)
        proxy.setShareEnabled(true)
        return try await awaitShare()
    }

    private func shareOff() async throws -> AutomationResponse {
        guard config().settings.proxyShareEnabled || shareIsUp else {
            return AutomationFields.response([shareBlock()])
        }
        proxy.setShareEnabled(false)
        let deadline = ContinuousClock.now + stopWait
        while shareIsUp, ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
        }
        if shareIsUp {
            return AutomationFields.response([shareBlock(message: L10n.automationShareStopPending)],
                                             code: AutomationExitCode.timedOut)
        }
        return AutomationFields.response([shareBlock()])
    }

    private func shareSet(_ request: AutomationProxyRequest) async throws -> AutomationResponse {
        let saved = config().proxy
        var updated = saved
        if let port = request.port { updated.port = port }
        if let engine = request.engine { updated.engine = engine }
        if let serviceName = request.serviceName { updated.serviceName = serviceName }
        if let auth = request.auth { updated.authEnabled = auth }
        if let username = request.username { updated.username = username }
        try requireStartable(updated)
        guard updated != saved else {
            return AutomationFields.response([shareBlock(restarted: false, message: L10n.automationShareUnchanged)])
        }
        // `saveShare` restarts exactly when the Proxy page's Save would: enabled and up.
        let restarts = config().settings.proxyShareEnabled && shareIsUp
        proxy.saveShare(updated)
        guard restarts else {
            return AutomationFields.response([shareBlock(restarted: false, message: L10n.automationShareSaved)])
        }
        return try await awaitShare(restarted: true)
    }

    /// What a person must fix in the UI before this share can start: gost, the password, the username.
    /// Checked before anything is saved or started, so a refusal changes nothing.
    private func requireStartable(_ share: ProxyShare) throws {
        if share.engine == .gost, proxy.shareCommand(for: share) == nil { throw AutomationRefusal.gostMissing }
        guard share.authEnabled else { return }
        // Without a username the generated config has no auth block at all — an open proxy
        // announced as protected.
        guard !share.username.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw AutomationRefusal.shareUsernameMissing
        }
        guard proxy.sharePassword()?.isEmpty == false else { throw AutomationRefusal.sharePasswordMissing }
    }

    private func awaitShare(restarted: Bool? = nil) async throws -> AutomationResponse {
        let deadline = ContinuousClock.now + startWait
        while true {
            if processManager?.portConflicts[ProxyShare.daemonID] != nil {
                return AutomationFields.response([shareBlock(restarted: restarted)], code: AutomationExitCode.failed)
            }
            switch proxy.shareState {
            case .daemonRunning?:
                return AutomationFields.response([shareBlock(restarted: restarted)])
            case .failed?:
                return AutomationFields.response([shareBlock(restarted: restarted, output: true)],
                                                 code: AutomationExitCode.failed)
            case .running?:
                break
            case nil, .idle?, .succeeded?:
                // `run` marks a daemon `.running` synchronously, so nothing was started
                // (the config file could not be written — the diagnostic log says why).
                return AutomationFields.response([shareBlock(restarted: restarted, message: L10n.automationShareNotStarted)],
                                                 code: AutomationExitCode.failed)
            }
            if ContinuousClock.now >= deadline {
                return AutomationFields.response(
                    [shareBlock(restarted: restarted, message: L10n.automationShareTimedOut(Int(startWait.components.seconds)))],
                    code: AutomationExitCode.timedOut)
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    // MARK: helpers

    private func tunnel(of remote: RemoteProxy) -> Command? {
        remote.tunnelCommandID.flatMap { config().commandsByID[$0] }
    }

    private static func isFailed(_ state: ProcessManager.RunState?) -> Bool {
        if case .failed? = state { return true }
        return false
    }

    private static func endpoint(_ host: String, _ port: Int) -> String { "\(host):\(port)" }

    private static func listing(_ choice: Choice) -> String {
        switch choice {
        case .lan(let found): "lan\t\(oneLine(found.name))\t-"
        case .remote(let remote): "remote\t\(oneLine(remote.name))\t\(remote.id.uuidString)"
        }
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
