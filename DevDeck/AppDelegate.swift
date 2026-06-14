import AppKit

/// Application delegate. Owns the shared observable objects (store/manager/UI model)
/// and the menu bar controller. Both the popover and the main window receive them — single state.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = CommandStore(defaultConfigData: AppDelegate.bundledDefaultConfig())
    let notifier = LiveNotifier()
    let manager: ProcessManager
    let appModel = AppModel()

    private var menuBar: MenuBarController?

    override init() {
        manager = ProcessManager(runner: RoutingCommandRunner(), notifier: notifier)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        DiagnosticLog.shared.installCrashHandlers()
        notifier.requestAuthorization()   // native notifications for daemons/command errors
        store.start()
        DiagnosticLog.shared.log("DevDeck launch: \(store.config.commands.count) commands, \(store.config.chains.count) chains")
        // Adopt daemons that survived a previous session (crash / "keep in background") → don't fight over the port.
        manager.adoptSurvivingDaemons(commands: store.commandsByID)
        // Read the memory-monitoring flags live from the config — no copy when they change.
        manager.isVMMonitoringEnabled = { [weak store] in store?.config.settings.vmMemoryMonitoring ?? false }
        manager.isMinikubeMonitoringEnabled = { [weak store] in store?.config.settings.minikubeMemoryMonitoring ?? false }
        menuBar = MenuBarController(store: store, manager: manager, appModel: appModel)
    }

    /// The main window's red close button does NOT quit the app — it lives in the menu bar.
    /// The window just disappears; bring it back via "Open DevDeck…". This also avoids the
    /// daemon-dialog loop when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// On quit with live daemons — show the "Kill / Keep in background / Cancel" dialog.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let daemons = manager.aliveDaemons
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
