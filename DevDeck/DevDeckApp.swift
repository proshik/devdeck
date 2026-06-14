import SwiftUI

/// Entry point. The app is an accessory (LSUIElement): no Dock icon,
/// lives in the menu bar. The main window does not open at launch (`.suppressed`) —
/// it is shown by the popover control panel via "Open DevDeck…" / ☰.
@main
struct DevDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("DevDeck", id: "main") {
            MainWindowView()
                .environment(appDelegate.store)
                .environment(appDelegate.manager)
                .environment(appDelegate.appModel)
        }
        .windowResizability(.contentMinSize)
        .defaultLaunchBehavior(.suppressed)
    }
}
