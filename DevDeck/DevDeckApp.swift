import SwiftUI

/// Starts in the menu bar (LSUIElement). Opening the full window enables Dock/Cmd-Tab;
/// closing it returns to accessory mode while background services keep running.
@main
struct DevDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(AppRuntime.developmentDirectory == nil ? "DevDeck" : L10n.deckDevelopmentTitle, id: "main") {
            MainWindowView()
                .environment(appDelegate.store)
                .environment(appDelegate.manager)
                .environment(appDelegate.appModel)
                .environment(appDelegate.updateController)
                .environment(appDelegate.proxyManager)
                .environment(appDelegate.cleanupModel)
                .environment(appDelegate.claudeTabs)
                .environment(appDelegate.engine)
                .environment(appDelegate.energy)
                .environment(appDelegate.awake)
                .environment(appDelegate.monitoring)
                .defaultAppStorage(AppRuntime.preferences)
        }
        .windowResizability(.contentMinSize)
        .defaultSize(width: 1080, height: 780)
        .defaultLaunchBehavior(AppRuntime.developmentDirectory == nil ? .suppressed : .presented)
        .commands { DevDeckCommands(appModel: appDelegate.appModel) }
    }
}

private struct DevDeckCommands: Commands {
    let appModel: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button(L10n.deckSettings) {
                appModel.showMainWindow(selection: .settings) {
                    openWindow(id: "main")
                    NSApp.activate()
                }
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}
