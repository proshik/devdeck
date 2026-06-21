import AppKit
import SwiftUI

/// Tray icon + popover control panel. Replaces the temporary menu from Stage 0.
@MainActor
final class MenuBarController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let manager: ProcessManager
    private var iconTimer: Timer?

    /// Colored pressure dot drawn over the (always-template) tray glyph. Kept as a separate
    /// non-template overlay so the glyph itself stays light/adaptive on a dark menu bar.
    private let badgeView: NSView = {
        let dot: CGFloat = 6
        let view = NSView(frame: NSRect(x: 0, y: 0, width: dot, height: dot))
        view.wantsLayer = true
        view.layer?.cornerRadius = dot / 2
        view.isHidden = true
        return view
    }()

    init(store: CommandStore, manager: ProcessManager, appModel: AppModel, updateController: UpdateController) {
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
                .environment(updateController)
        )

        if let button = statusItem.button {
            button.image = TrayIcon.image()   // always template → stays light/adaptive on a dark menu bar
            button.image?.accessibilityDescription = "DevDeck"
            button.action = #selector(togglePopover)
            button.target = self

            // Pin the dot to the top-right corner of the glyph box via constraints, so it
            // resolves at layout time (button.bounds isn't final yet during init) and the
            // glyph is centered in the taller status-bar button. Offsets derive from the glyph
            // size so the dot follows the glyph if its dimensions ever change.
            let d = badgeView.frame.width
            let half = TrayIcon.glyphSize / 2
            badgeView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(badgeView)
            NSLayoutConstraint.activate([
                badgeView.widthAnchor.constraint(equalToConstant: d),
                badgeView.heightAnchor.constraint(equalToConstant: d),
                badgeView.trailingAnchor.constraint(equalTo: button.centerXAnchor, constant: half),
                badgeView.topAnchor.constraint(equalTo: button.centerYAnchor, constant: -half),
            ])
        }

        // The pressure badge is a system indicator: read the level directly (cheap sysctl) so it
        // works even when no command is running. (`cachedHostSample` only exists during a run.)
        iconTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let level = self.manager.isHostMonitoringEnabled() ? currentMemoryPressureLevel() : .normal
                if let color = TrayIcon.badgeColor(for: level) {
                    self.badgeView.layer?.backgroundColor = color.cgColor
                    self.badgeView.isHidden = false
                } else {
                    self.badgeView.isHidden = true
                }
            }
        }
    }

    /// Public entry point for the global hotkey.
    func toggle() { togglePopover() }

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
