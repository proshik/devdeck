import AppKit

/// Application delegate. Owns the shared observable objects (store/manager/UI model)
/// and the menu bar controller. Both the popover and the main window receive them — single state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = CommandStore(defaultConfigData: AppDelegate.bundledDefaultConfig())
    let notifier = LiveNotifier()
    let manager: ProcessManager
    let appModel = AppModel()
    let updateController = UpdateController()
    let proxyManager = ProxyManager()
    let cleanupModel: CleanupModel

    private var menuBar: MenuBarController?

    override init() {
        manager = ProcessManager(runner: RoutingCommandRunner(), notifier: notifier)
        cleanupModel = CleanupModel(manager: manager)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLog.shared.installCrashHandlers()
        AppearanceManager.shared.apply()   // apply the persisted Light/Dark/System choice app-wide
        notifier.requestAuthorization()   // native notifications for daemons/command errors
        store.start()
        DiagnosticLog.shared.log("DevDeck launch: \(store.config.commands.count) commands, \(store.config.chains.count) chains")
        // Adopt daemons that survived a previous session (crash / "keep in background") → don't fight over the port.
        manager.adoptSurvivingDaemons(commands: store.commandsByID)
        // Read the memory-monitoring flags live from the config — no copy when they change.
        manager.isVMMonitoringEnabled = { [weak store] in store?.config.settings.vmMemoryMonitoring ?? false }
        manager.isMinikubeMonitoringEnabled = { [weak store] in store?.config.settings.minikubeMemoryMonitoring ?? false }
        manager.isHostMonitoringEnabled = { [weak store] in store?.config.settings.hostMemoryMonitoring ?? false }
        manager.isClusterHealthEnabled = { [weak store] in store?.config.settings.clusterHealthMonitoring ?? false }
        // Proxy Manager: shares this machine's VPN egress and routes flagged commands through a peer's.
        // The routing hook is a closure so ProcessManager keeps no dependency on ProxyManager.
        let proxyManager = self.proxyManager
        proxyManager.store = store
        proxyManager.processManager = manager
        manager.proxyRouting = { [weak proxyManager] command in
            proxyManager?.routing(for: command) ?? .notRouted
        }
        // The listener's own log lines are where "who is connected" comes from.
        manager.outputObserver = { [weak proxyManager] commandID, line, _ in
            proxyManager?.ingestDaemonOutput(commandID, line)
        }
        proxyManager.start()
        // Start Sparkle with the persisted auto-update preference; populates the indicator when off.
        updateController.configure(autoUpdateEnabled: store.config.settings.autoUpdateEnabled)
        menuBar = MenuBarController(store: store, manager: manager, appModel: appModel,
                                    updateController: updateController, proxyManager: proxyManager)

        // Global hotkey (⌃⌥D) toggles the popover; enabled per the persisted setting.
        HotKeyManager.shared.onTrigger = { [weak menuBar] in menuBar?.toggle() }
        HotKeyManager.shared.setEnabled(store.config.settings.globalHotkeyEnabled)

        // Run directories are no longer deleted when a command finishes — a live tab keeps its
        // script around for diagnosing. Collect the ones whose terminal is gone now instead.
        sweepStaleTerminalDirectories()
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
        }
        guard !daemons.isEmpty else {
            DiagnosticLog.shared.log("Quit (no live daemons)")
            return .terminateNow
        }

        NSApp.activate()   // bring the dialog to the front for an accessory app
        let alert = NSAlert()
        alert.messageText = L10n.exitDaemonsActive(daemons.count)
        alert.informativeText = L10n.exitDaemonsQuestion
        alert.addButton(withTitle: L10n.exitKill)            // .alertFirstButtonReturn
        alert.addButton(withTitle: L10n.exitKeepInBackground)  // .alertSecondButtonReturn
        alert.addButton(withTitle: L10n.cancel)              // .alertThirdButtonReturn

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            DiagnosticLog.shared.log("Quit: kill \(daemons.count) daemons", level: .warn)
            daemons.forEach { manager.stop($0) }   // SIGTERM synchronously → ports are freed
            return .terminateNow
        case .alertSecondButtonReturn:
            DiagnosticLog.shared.log("Quit: keep \(daemons.count) daemons in background")
            return .terminateNow                   // daemons reparent to launchd and keep running
        default:
            DiagnosticLog.shared.log("Quit cancelled")
            return .terminateCancel
        }
    }

    /// Bundled starter config with examples (copied on first launch if config.json is absent).
    private nonisolated static func bundledDefaultConfig() -> Data? {
        Bundle.main.url(forResource: "default-config", withExtension: "json")
            .flatMap { try? Data(contentsOf: $0) }
    }
}
