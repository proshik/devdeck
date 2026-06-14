import AppKit
import SwiftUI

/// Tray icon + popover control panel. Replaces the temporary menu from Stage 0.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let manager: ProcessManager
    private var iconTimer: Timer?

    init(store: CommandStore, manager: ProcessManager, appModel: AppModel) {
        self.manager = manager
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

        // The pressure badge is a system indicator: read the level directly (cheap sysctl) so it
        // works even when no command is running. (`cachedHostSample` only exists during a run.)
        iconTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.statusItem.button else { return }
                let level = self.manager.isHostMonitoringEnabled() ? currentMemoryPressureLevel() : .normal
                button.image = TrayIcon.image(pressureColor: TrayIcon.badgeColor(for: level))
                button.image?.accessibilityDescription = "DevDeck"
            }
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
