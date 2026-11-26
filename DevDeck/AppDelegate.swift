import AppKit
import ServiceManagement

/// Application delegate. Owns the shared observable objects (store/manager/UI model)
/// and the menu bar controller. Both the popover and the main window receive them — single state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = CommandStore(defaultConfigData: AppRuntime.isIsolated ? nil : AppDelegate.bundledDefaultConfig())
    let notifier = LiveNotifier(asksOnFirstRun: !AppRuntime.isIsolated)
    let manager: ProcessManager
    let appModel = AppModel()
    let updateController = UpdateController()
    let proxyManager: ProxyManager = {
        let credentials: any ProxyCredentialStore = AppRuntime.isIsolated
            ? SessionProxyCredentialStore() : KeychainProxyCredentialStore()
        return ProxyManager(credentials: credentials)
    }()
    let cleanupModel: CleanupModel
    let diskOverview: DiskOverviewModel
    let claudeTabs = ClaudeTabsModel(defaults: AppRuntime.preferences)
    let energy = EnergyModel()
    let awake: AwakeModel
    let engine = EngineModel()
    let monitoring: DeckMonitoringModel
    let clipboard = ClipboardModel(paster: ClipboardPasteController())
    let brightness = DisplayBrightnessModel()
    private(set) lazy var permissions = PermissionsModel(probe: LivePermissionProbe(), flags: { [weak store] in
        PermissionFeatureFlags(config: store?.config ?? .empty,
                               launchAtLogin: SMAppService.mainApp.status == .enabled)
    })

    /// Crash-loop protection (REC-01). Its own 0600 file beside the config; never writes config.json.
    private(set) lazy var recovery: RecoveryModel = {
        let directory = AppRuntime.supportDirectory
        return RecoveryModel(
            storage: FileRecoveryStorage(url: directory.appendingPathComponent("recovery.json")),
            markers: AppRuntime.isTesting ? nil
                : FileRecoveryMarkerStorage(url: directory.appendingPathComponent("recovery-markers")),
            bootTime: { Int(LiveBootTime().bootTime().timeIntervalSince1970) },
            installedBuild: Bundle.main.buildVersion,
            notify: { [weak self] modules in
                self?.notifier.post(.modulesSuspended(names: modules.map(L10n.recoveryModule).joined(separator: ", ")))
            })
    }()

    private var menuBar: MenuBarController?
    private var automationSocket: AutomationSocketServer?
    private lazy var termination = AppTerminationCoordinator(network: monitoring.network)

    override init() {
        manager = ProcessManager(runner: RoutingCommandRunner(), notifier: notifier)
        cleanupModel = CleanupModel(manager: manager)
        diskOverview = DiskOverviewModel(cleanup: cleanupModel, root: AppRuntime.diskScanRoot)
        awake = AwakeModel(manager: manager)
        monitoring = DeckMonitoringModel(manager: manager, energy: energy, store: store, engine: engine)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard !AppRuntime.isTesting else { return }
        DiagnosticLog.shared.installCrashHandlers()
        // First: judge how the previous process ended, before any module can crash this one.
        recovery.launch()
        recovery.onResume = { [weak self] module in self?.resume(module) }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(RecoveryPolicy.earlyWindow))
            self?.recovery.markSurvivedEarlyWindow()
        }
        let mark: RecoveryMarking = { [weak self] operation, running in
            if running { self?.recovery.begin(operation) } else { self?.recovery.end(operation) }
        }
        brightness.markOperation = mark
        claudeTabs.markOperation = mark
        monitoring.markOperation = mark
        updateController.willInstall = { [weak self] build in self?.recovery.updateWillInstall(build: build) }
        updateController.setAutoInstallSuspended(recovery.isSuspended(.autoUpdateInstall))
        applyMonitoringHalt()
        AppearanceManager.shared.apply()   // apply the persisted Light/Dark/System choice app-wide
        store.start()
        DiagnosticLog.shared.log("DevDeck launch: \(store.config.commands.count) commands, \(store.config.chains.count) chains")
        // The engine is known before the first probe asks for it; the tray timer keeps it fresh.
        engine.preference = { [weak store] in store?.config.settings.containerEngine ?? .auto }
        engine.refresh()
        // Adopt daemons that survived a previous session (crash / "keep in background") → don't fight over the port.
        if !AppRuntime.isIsolated { manager.adoptSurvivingDaemons(commands: store.commandsByID) }
        // Read the memory-monitoring flags live from the config — no copy when they change.
        // The VM memory/disk and cluster probes speak `colima ssh`/`colima list`: under another
        // engine they stay off (caches cleared) instead of reporting a stopped colima.
        // Recovery can halt monitoring without touching these flags in config.json.
        let monitoringOn = { [weak self] in self.map { !$0.recovery.isSuspended(.monitoring) } ?? false }
        manager.isVMMonitoringEnabled = { [weak store, weak engine] in
            (store?.config.settings.vmMemoryMonitoring ?? false) && engine?.activeKind == .colima && monitoringOn()
        }
        manager.isMinikubeMonitoringEnabled = { [weak store] in
            (store?.config.settings.minikubeMemoryMonitoring ?? false) && monitoringOn()
        }
        manager.isHostMonitoringEnabled = { [weak store] in
            (store?.config.settings.hostMemoryMonitoring ?? false) && monitoringOn()
        }
        manager.isClusterHealthEnabled = { [weak store, weak engine] in
            (store?.config.settings.clusterHealthMonitoring ?? false) && engine?.activeKind == .colima && monitoringOn()
        }
        // Proxy Manager: shares this machine's VPN egress and routes flagged commands through a peer's.
        // The routing hook is a closure so ProcessManager keeps no dependency on ProxyManager.
        let proxyManager = self.proxyManager
        proxyManager.store = store
        proxyManager.processManager = manager
        manager.proxyRouting = { [weak proxyManager] command in
            proxyManager?.routing(for: command) ?? .notRouted
        }
        // The listener's own log lines are where "who is connected" comes from.
        manager.outputObserver = { [weak proxyManager] commandID, line, stream in
            proxyManager?.ingestDaemonOutput(commandID, line, stream)
        }
        if !AppRuntime.isIsolated { proxyManager.start() }
        // Shortcuts actions (App Intents) reach saved commands and chains through this service.
        // It reads the config live, so the settings switch and the per-item flags apply at once.
        let automation = AutomationService(manager: manager, config: { [weak store] in store?.config ?? .empty })
        AutomationHost.service = automation
        // `DevDeck automation …` reaches the same service over a local socket — it works with the
        // ad-hoc signature, which App Intents do not.
        if !recovery.isSuspended(.automationCLI) { startAutomationSocket(automation) }
        // Start Sparkle with the persisted auto-update preference; populates the indicator when off.
        if !AppRuntime.isIsolated {
            updateController.configure(autoUpdateEnabled: store.config.settings.autoUpdateEnabled)
        }
        menuBar = MenuBarController(store: store, manager: manager, appModel: appModel,
                                    updateController: updateController, proxyManager: proxyManager,
                                    claudeTabs: claudeTabs, energy: energy, engine: engine, awake: awake,
                                    monitoring: monitoring, clipboard: clipboard, brightness: brightness,
                                    recovery: recovery)
        if !recovery.isSuspended(.brightness) { startBrightness() }
        clipboard.dismissPanel = { [weak appModel] in appModel?.dismissPanel() }
        if !recovery.isSuspended(.clipboard) { startClipboard() }
        if !AppRuntime.isIsolated { awake.startMonitoring() }
        energy.isEnabled = { [weak store] in (store?.config.settings.batteryMonitoring ?? false) && monitoringOn() }
        energy.start()
        monitoring.start(store: store, engine: engine, manager: manager)

        // Global hotkey (⌃⌥D) toggles the popover; enabled per the persisted setting.
        HotKeyManager.shared.onTrigger = { [weak menuBar] in menuBar?.toggle() }
        if !AppRuntime.isIsolated {
            HotKeyManager.shared.setEnabled(store.config.settings.globalHotkeyEnabled)
        }

        // Run directories are no longer deleted when a command finishes — a live tab keeps its
        // script around for diagnosing. Collect the ones whose terminal is gone now instead.
        if !AppRuntime.isIsolated { sweepStaleTerminalDirectories() }

        // Switched off by recovery: no capture either, so the snapshot on disk stays untouched.
        if !recovery.isSuspended(.agentTabRestore) { startClaudeTabs() }
    }

    private func startBrightness() {
        brightness.start(settings: { [weak store] in store?.config.settings.displays ?? .init() })
    }

    private func startClipboard() {
        clipboard.start(settings: { [weak store] in store?.config.settings.clipboard ?? .init() })
    }

    private func applyMonitoringHalt() {
        monitoring.setHalted(monitoring: recovery.isSuspended(.monitoring), network: recovery.isSuspended(.network))
    }

    /// A module the user switched back on starts now, without a relaunch.
    private func resume(_ module: RecoveryModule) {
        switch module {
        case .clipboard: startClipboard()
        case .brightness: startBrightness()
        case .monitoring, .network: applyMonitoringHalt()
        case .agentTabRestore: startClaudeTabs()
        case .autoUpdateInstall: updateController.setAutoInstallSuspended(false)
        case .automationCLI:
            if automationSocket == nil, let service = AutomationHost.service { startAutomationSocket(service) }
        }
    }

    private func startClaudeTabs() {
        // Snapshots of the coding-agent tabs, and the post-reboot restore.
        // Both closures read live from the config, so a hand-edited config.json — the flag or the
        // interval — takes effect without a relaunch. Development launches use their own
        // snapshot and preferences; hosted tests return before starting any services.
        claudeTabs.start(isEnabled: { [weak store] in store?.config.settings.claudeTabsRestore ?? false },
                         captureInterval: { [weak store] in
                             ClaudeTabsCaptureInterval.clamped(
                                 store?.config.settings.claudeTabsCaptureSeconds
                                     ?? ClaudeTabsCaptureInterval.fallback)
                         })
    }

    /// Listen for the command line. The socket is per bundle id and data directory, so a
    /// development build never answers for the installed DevDeck. A failure costs only the CLI.
    private func startAutomationSocket(_ service: AutomationService) {
        // Brightness goes through the same model as the keys and the slider (and its OSD).
        let brightness = BrightnessAutomation(model: self.brightness, config: { [weak store] in store?.config ?? .empty })
        // Proxy and keep-awake go through the same managers as the popover and the Proxy page.
        let config: () -> Config = { [weak store] in store?.config ?? .empty }
        let router = AutomationRequestRouter(service: service, brightness: brightness,
                                             proxy: ProxyAutomation(proxy: proxyManager, config: config),
                                             awake: AwakeAutomation(model: awake, config: config))
        let url = AutomationEndpoint.socketURL(bundleID: Bundle.main.bundleIdentifier ?? "DevDeck",
                                               dataDirectory: AppRuntime.supportDirectory)
        let server = AutomationSocketServer(socketURL: url) { request in await router.handle(request) }
        do {
            try server.start()
            automationSocket = server
            DiagnosticLog.shared.log("Automation: command line listening at \(url.path)")
        } catch {
            DiagnosticLog.shared.log("Automation: command line unavailable — \(error)", level: .warn)
        }
    }

    /// Last snapshot before quitting, so a crash-free quit never loses the most recent tab layout.
    ///
    /// `captureBeforeShutdown`, not `captureNow`: quitting is an automatic path and must respect
    /// the feature flag, unlike the explicit "Capture now" action which deliberately bypasses it.
    /// And not `captureIfEnabled` either — this method cannot await, so it needs the synchronous
    /// path rather than the asynchronous one, which macOS may never run. What that path costs is
    /// documented on `captureBeforeShutdown` itself; it is not unconditionally bounded.
    func applicationWillTerminate(_ notification: Notification) {
        guard !AppRuntime.isTesting else { return }
        automationSocket?.stop()
        awake.stop()   // the privileged helper restores sleep even after this process exits
        monitoring.stop()
        clipboard.stop()
        brightness.stop()
        claudeTabs.captureBeforeShutdown()
        recovery.markCleanExit()   // last: a crash in the shutdown work above is still a crash
    }

    /// The main window's red close button does NOT quit the app — it lives in the menu bar.
    /// The window just disappears; bring it back via "Open DevDeck…". This also avoids the
    /// daemon-dialog loop when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// On quit with live daemons — show the "Kill / Keep in background / Cancel" dialog.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // In-process listeners cannot be "kept in background", and both auto-restore on the next
        // launch — so neither triggers the dialog nor gets counted: the share's built-in engine
        // and the remote proxy's bridge. The gost engine and the ssh tunnel are real processes
        // and keep today's daemon semantics.
        let daemons = manager.aliveDaemons.filter {
            !($0 == ProxyShare.daemonID && store.config.proxy.engine == .builtIn)
                && $0 != RemoteProxy.bridgeDaemonID
                && $0 != AwakeHelper.daemonID   // this lease always ends with the app
        }
        return termination.request(daemons: daemons, choose: { self.chooseDaemonQuit(count: daemons.count) },
                                   stopDaemon: { self.manager.stop($0) },
                                   reply: { sender.reply(toApplicationShouldTerminate: $0) })
    }

    private func chooseDaemonQuit(count: Int) -> AppTerminationCoordinator.DaemonChoice {
        NSApp.activate()   // bring the dialog to the front for an accessory app
        let alert = NSAlert()
        alert.messageText = L10n.exitDaemonsActive(count)
        alert.informativeText = L10n.exitDaemonsQuestion
        alert.addButton(withTitle: L10n.exitKill)
        alert.addButton(withTitle: L10n.exitKeepInBackground)
        alert.addButton(withTitle: L10n.cancel)
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .kill
        case .alertSecondButtonReturn: return .leaveBackground
        default: return .cancel
        }
    }

    /// Bundled starter config with examples (copied on first launch if config.json is absent).
    private nonisolated static func bundledDefaultConfig() -> Data? {
        Bundle.main.url(forResource: "default-config", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
    }
}
