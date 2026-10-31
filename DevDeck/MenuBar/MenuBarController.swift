import AppKit
import Observation
import SwiftUI

/// Tray icon + popover control panel. Replaces the temporary menu from Stage 0.
@MainActor
final class MenuBarController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let manager: ProcessManager
    private let store: CommandStore
    private let engine: EngineModel
    private let appModel: AppModel
    private let monitoring: DeckMonitoringModel
    private let clipboard: ClipboardModel
    private let monitoringReader = UUID()
    private var appearanceBinding: PopoverAppearanceBinding?
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

    /// Green dot bottom-left while the container engine runs — the counterpart of the pressure dot.
    private let engineBadgeView: NSView = {
        let dot: CGFloat = 6
        let view = NSView(frame: NSRect(x: 0, y: 0, width: dot, height: dot))
        view.wantsLayer = true
        view.layer?.cornerRadius = dot / 2
        view.isHidden = true
        return view
    }()

    init(store: CommandStore, manager: ProcessManager, appModel: AppModel,
         updateController: UpdateController, proxyManager: ProxyManager, claudeTabs: ClaudeTabsModel,
         energy: EnergyModel, engine: EngineModel, awake: AwakeModel, monitoring: DeckMonitoringModel,
         clipboard: ClipboardModel? = nil, brightness: DisplayBrightnessModel? = nil,
         popover suppliedPopover: NSPopover? = nil) {
        let popover = suppliedPopover ?? NSPopover()
        self.manager = manager
        self.store = store
        self.engine = engine
        self.appModel = appModel
        self.monitoring = monitoring
        self.clipboard = clipboard ?? ClipboardModel()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.popover = popover
        super.init()

        appModel.dismissPanel = { [weak self] in self?.popover.performClose(nil) }

        popover.behavior = .transient
        popover.delegate = self
        let hosting = NSHostingController(
            rootView: PopoverView()
                .environment(store)
                .environment(manager)
                .environment(appModel)
                .environment(updateController)
                .environment(proxyManager)
                .environment(claudeTabs)
                .environment(energy)
                .environment(engine)
                .environment(awake)
                .environment(monitoring)
                .environment(self.clipboard)
                .environment(brightness ?? DisplayBrightnessModel())
                .defaultAppStorage(AppRuntime.preferences)
        )
        popover.contentViewController = hosting
        appearanceBinding = PopoverAppearanceBinding(popover)

        if let button = statusItem.button {
            button.toolTip = AppRuntime.isIsolated ? L10n.deckDevelopmentTitle : "DevDeck"
            button.image = TrayIcon.image()   // always template → stays light/adaptive on a dark menu bar
            button.image?.accessibilityDescription = "DevDeck"
            button.action = #selector(togglePopover)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])

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

            // Engine dot: bottom-left, the counterpart of the pressure dot top-right.
            engineBadgeView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(engineBadgeView)
            NSLayoutConstraint.activate([
                engineBadgeView.widthAnchor.constraint(equalToConstant: d),
                engineBadgeView.heightAnchor.constraint(equalToConstant: d),
                engineBadgeView.leadingAnchor.constraint(equalTo: button.centerXAnchor, constant: -half),
                engineBadgeView.bottomAnchor.constraint(equalTo: button.centerYAnchor, constant: half),
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

                self.engine.refresh()
                if let color = TrayIcon.engineBadgeColor(running: self.engine.isActiveRunning) {
                    self.engineBadgeView.layer?.backgroundColor = color.cgColor
                    self.engineBadgeView.isHidden = false
                } else {
                    self.engineBadgeView.isHidden = true
                }
                self.statusItem.button?.image?.accessibilityDescription =
                    L10n.trayAccessibility(engineName: self.engine.activeName, running: self.engine.isActiveRunning)
            }
        }
    }

    /// Public entry point for the global hotkey.
    func toggle() { togglePanel(focusPicker: true) }

    func popoverWillShow(_ notification: Notification) {
        appModel.panelSection = store.config.panel.openingSection ?? .environment
        monitoring.begin(monitoringReader)
    }
    func popoverDidClose(_ notification: Notification) { monitoring.end(monitoringReader) }

    @objc private func togglePopover() {
        if let event = NSApp.currentEvent,
           event.type == .rightMouseUp || event.modifierFlags.contains(.control),
           let button = statusItem.button {
            popover.performClose(nil)
            let menu = NSMenu()
            let quit = NSMenuItem(title: L10n.quit, action: #selector(quitFromMenu), keyEquivalent: "q")
            quit.target = self
            menu.addItem(quit)
            NSMenu.popUpContextMenu(menu, with: event, for: button)
            return
        }
        togglePanel(focusPicker: false)
    }

    @objc private func quitFromMenu() {
        // With live daemons the application delegate supplies the Kill / Keep / Cancel dialog.
        guard !manager.hasLiveDaemons() else {
            NSApp.terminate(nil)
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L10n.quitConfirmTitle
        alert.informativeText = L10n.quitConfirmMessage
        alert.addButton(withTitle: L10n.quitButton)
        alert.addButton(withTitle: L10n.cancel)
        if alert.runModal() == .alertFirstButtonReturn { NSApp.terminate(nil) }
    }

    private func togglePanel(focusPicker: Bool) {
        guard let button = statusItem.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            clipboard.capturePasteTarget()
            let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) }
                ?? button.window?.screen ?? NSScreen.main
            appModel.panelContentHeightLimit = min(560, max(120, (screen?.visibleFrame.height ?? 800) - 160))
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            if let window = popover.contentViewController?.view.window {
                window.makeKey()
                // Mouse opening starts without an automatic focus ring. Tab navigation and
                // opening with the global hotkey retain the native keyboard focus indication.
                if !focusPicker { window.makeFirstResponder(nil) }
            }
        }
    }
}
