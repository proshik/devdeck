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
    private var engineTimer: Timer?

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
        }

        // Engine detection is subprocess-free and feeds the panel labels and probe gates; the
        // icon itself stays a plain template glyph (no status dots, decision 2026-11-21).
        engineTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.engine.refresh()
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
