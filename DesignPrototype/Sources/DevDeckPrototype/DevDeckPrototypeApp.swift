import AppKit
import SwiftUI

@main
struct DevDeckPrototypeApp: App {
    @NSApplicationDelegateAdaptor(PrototypeAppDelegate.self) private var delegate
    @State private var model = PrototypeModel()

    var body: some Scene {
        Window("DevDeck — прототип", id: "main") {
            PrototypeWindow()
                .environment(model)
                .preferredColorScheme(model.appearance.scheme)
        }
        .defaultSize(width: 1080, height: 780)
        .defaultLaunchBehavior(.presented)
        .windowResizability(.contentMinSize)
        .commands { PrototypeCommands(model: model) }

        Window("Панель DevDeck — прототип", id: "panel") {
            PrototypePanelWindow()
                .environment(model)
                .preferredColorScheme(model.appearance.scheme)
        }
        .defaultLaunchBehavior(.suppressed)
        .windowResizability(.contentSize)

        MenuBarExtra {
            PrototypePanel()
                .environment(model)
                .preferredColorScheme(model.appearance.scheme)
        } label: {
            PrototypeTrayLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

private struct PrototypeTrayLabel: View {
    @Environment(\.openWindow) private var openWindow
    @State private var opened = false
    var body: some View {
        Label("DevDeck — прототип", systemImage: "square.grid.2x2")
            .task {
                // Open from an installed SwiftUI environment, also when run as a package in Xcode.
                guard !opened else { return }
                opened = true
                openWindow(id: "main")
            }
    }
}

@MainActor
final class PrototypeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
    }
}

private struct PrototypeCommands: Commands {
    let model: PrototypeModel
    @Environment(\.openWindow) private var openWindow
    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Настройки DevDeck…") { model.navigate(.general); openWindow(id: "main") }
                .keyboardShortcut(",", modifiers: [.command])
        }
        CommandGroup(after: .appInfo) {
            Button("Обновления DevDeck…") { model.navigate(.updates); openWindow(id: "main") }
        }
        CommandGroup(after: .windowArrangement) {
            Button("Панель и сценарии") { openWindow(id: "panel") }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}

#Preview("Конфигурация · macOS") {
    PrototypeWindow().environment(PrototypeModel()).frame(width: 1080, height: 780)
}

#Preview("Панель · macOS") {
    PrototypePanel().environment(PrototypeModel())
}
