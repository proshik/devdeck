import AppKit
import SwiftUI

/// Tray icon + popover control panel. Replaces the temporary menu from Stage 0.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    init(store: CommandStore, manager: ProcessManager, appModel: AppModel) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()

        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: PopoverView()
                .environment(store)
                .environment(manager)
                .environment(appModel)
        )

        if let button = statusItem.button {
            button.image = TrayIcon.image()
            button.image?.accessibilityDescription = "DevDeck"
            button.action = #selector(togglePopover)
            button.target = self
        }
    }

    @objc private func togglePopover() {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}
