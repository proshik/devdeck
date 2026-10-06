import AppKit
import SwiftUI
import XCTest
@testable import DevDeck

@MainActor
final class PanelLayoutTests: XCTestCase {
    func testPanelFitsShortContentAndScrollsLongContentWithWorkingNativePicker() async throws {
        let previousActivationPolicy = NSApp.activationPolicy()
        defer { NSApp.setActivationPolicy(previousActivationPolicy) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommandStore(configURL: directory.appendingPathComponent("config.json"))
        try store.save(.empty)
        let manager = ProcessManager(runner: FakeCommandRunner(), vmMonitoringEnabled: { false },
                                     hostMonitoringEnabled: { false })
        let appModel = AppModel()
        let engine = EngineModel(candidates: [])
        let energy = EnergyModel(batteryProbe: FakeBatteryProbe(), energyProbe: FakeProcessEnergyProbe(),
                                 observer: FakePowerSourceObserver())
        let proxy = ProxyManager(discovering: FakeProxyDiscovering(), advertiser: FakeProxyAdvertising(),
                                 credentials: FakeProxyCredentialStore())
        let root = PopoverView()
            .environment(store).environment(manager).environment(appModel)
            .environment(UpdateController()).environment(energy).environment(engine).environment(proxy)
            .environment(ClaudeTabsModel(defaults: AppRuntime.preferences))
            .environment(AwakeModel(manager: manager, hasJournal: { false }))
            .defaultAppStorage(AppRuntime.preferences)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -2000, y: -2000))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(200))
        hosting.view.layoutSubtreeIfNeeded()
        let shortSize = hosting.view.fittingSize
        XCTAssertEqual(shortSize.width, 380, accuracy: 2)
        XCTAssertLessThan(shortSize.height, 400, "an empty panel must not reserve the old 675 pt")
        let picker = try XCTUnwrap(findPicker(in: hosting.view))
        XCTAssertEqual((0..<picker.segmentCount).map { picker.toolTip(forSegment: $0) }, PanelSection.allCases.map(\.title))
        picker.selectedSegment = 2
        let action = try XCTUnwrap(picker.action)
        NSApp.sendAction(action, to: picker.target, from: picker)
        XCTAssertEqual(appModel.panelSection, .displays)
        let previousLanguage = LocalizationManager.shared.language
        let previousAppearance = NSApp.appearance
        defer {
            LocalizationManager.shared.language = previousLanguage
            NSApp.appearance = previousAppearance
        }
        for language in AppLanguage.allCases {
            LocalizationManager.shared.language = language
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                for section in PanelSection.allCases {
                    appModel.panelSection = section
                    try await Task.sleep(for: .milliseconds(100))
                    hosting.view.layoutSubtreeIfNeeded()
                    XCTAssertEqual((0..<picker.segmentCount).map { picker.toolTip(forSegment: $0) }, PanelSection.allCases.map(\.title))
                    XCTAssertLessThan(hosting.view.fittingSize.height, 700)
                    XCTAssertEqual(picker.selectedSegment, PanelSection.allCases.firstIndex(of: section))
                    try saveSnapshot(hosting.view, name: "panel-\(section.rawValue)-\(language.rawValue)-\(appearance.rawValue)")
                }
            }
        }
        appModel.panelSection = .environment
        for index in 0..<50 {
            store.upsert(Command(id: UUID(), name: "Command \(index)", command: "echo ok"))
        }
        try await Task.sleep(for: .milliseconds(200))
        hosting.view.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(hosting.view.fittingSize.height, shortSize.height)
        XCTAssertLessThan(hosting.view.fittingSize.height, 700, "long content must scroll within the cap plus the header")
        try saveSnapshot(hosting.view, name: "panel-long")
        appModel.panelContentHeightLimit = 120
        try await Task.sleep(for: .milliseconds(100))
        hosting.view.layoutSubtreeIfNeeded()
        XCTAssertLessThan(hosting.view.fittingSize.height, 270, "the panel must fit a screen with limited space")

        // NSPopover has its own sizing behavior; fittingSize in a window alone is insufficient.
        let screen = try XCTUnwrap(NSScreen.main)
        let anchorWindow = NSWindow(contentRect: NSRect(x: screen.visibleFrame.minX + 20,
                                                       y: screen.visibleFrame.maxY - 40,
                                                       width: 40, height: 20),
                                    styleMask: .borderless, backing: .buffered, defer: false)
        anchorWindow.isReleasedWhenClosed = false
        let anchor = NSView(frame: NSRect(x: 0, y: 0, width: 40, height: 20))
        anchorWindow.contentView = anchor
        anchorWindow.orderBack(nil)
        let popover = NSPopover()
        popover.animates = false
        popover.behavior = .applicationDefined
        popover.contentViewController = NSHostingController(rootView: root)
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        defer { popover.performClose(nil); anchorWindow.close() }
        try await Task.sleep(for: .milliseconds(150))
        let popoverContent = try XCTUnwrap(popover.contentViewController?.view.window?.contentView)
        let compactPopoverHeight = popoverContent.bounds.height
        XCTAssertEqual(popoverContent.bounds.width, 380, accuracy: 2)
        XCTAssertLessThan(compactPopoverHeight, 270)
        appModel.panelContentHeightLimit = 560
        appModel.panelSection = .monitoring
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertGreaterThan(popoverContent.bounds.height, compactPopoverHeight,
                             "the real popover must resize when switching sections")
        XCTAssertLessThan(popoverContent.bounds.height, 400)
        popover.performClose(nil)

        let mainRoot = MainWindowView()
            .environment(store).environment(manager).environment(appModel)
            .environment(UpdateController()).environment(energy).environment(engine).environment(proxy)
            .environment(ClaudeTabsModel(defaults: AppRuntime.preferences))
            .environment(AwakeModel(manager: manager, hasJournal: { false }))
            .environment(CleanupModel(manager: manager, probe: FakeDockerUsageProbe([:])))
            .environment(DeckMonitoringModel(interval: .milliseconds(20), refresh: {}, refreshHeavy: {}))
            .defaultAppStorage(AppRuntime.preferences)
        let mainHosting = NSHostingController(rootView: mainRoot)
        let mainWindow = NSWindow(contentViewController: mainHosting)
        mainWindow.isReleasedWhenClosed = false
        mainWindow.setContentSize(NSSize(width: 1080, height: 780))
        mainWindow.setFrameOrigin(NSPoint(x: -2500, y: -2500))
        mainWindow.orderFront(nil)
        defer { mainWindow.close() }
        for selection in [MainSelection.settings, .commands, .panel, .updates, .monitoring, .containers, .energy, .awake, .ports] {
            appModel.selection = selection
            try await Task.sleep(for: .milliseconds(100))
            mainHosting.view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(mainHosting.view.bounds.width, 860)
            try saveSnapshot(mainHosting.view, name: "window-\(selection)")
        }

        // A logs link from the tray must keep its command and tab selected even though the
        // outer sidebar selects the whole workspace. Moving between settings and that workspace
        // must not let either native List clear the detail selection during a layout update.
        let command = try XCTUnwrap(store.config.commands.first)
        let chain = Chain(id: UUID(), name: "UI test chain", commandIDs: [command.id])
        store.upsert(chain)
        for selection in [MainSelection.command(command.id), .chain(chain.id)] {
            appModel.selection = .settings
            try await Task.sleep(for: .milliseconds(100))
            appModel.detailTab = .logs
            appModel.selection = selection
            try await Task.sleep(for: .milliseconds(150))
            mainHosting.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(appModel.selection, selection)
            XCTAssertEqual(appModel.detailTab, .logs)
            try saveSnapshot(mainHosting.view, name: "workspace-\(selection)-logs")
            appModel.detailTab = .editor
            try await Task.sleep(for: .milliseconds(100))
            mainHosting.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(appModel.selection, selection)
            XCTAssertEqual(appModel.detailTab, .editor)
            try saveSnapshot(mainHosting.view, name: "workspace-\(selection)-editor")
        }

        // Use the real menu bar controller's dismiss wiring. Opening another window of this
        // app must close the popover before bringing up the requested settings page.
        let routedPopover = NSPopover()
        routedPopover.animates = false
        let menuBar = MenuBarController(
            store: store, manager: manager, appModel: appModel, updateController: UpdateController(),
            proxyManager: proxy, claudeTabs: ClaudeTabsModel(defaults: AppRuntime.preferences),
            energy: energy, engine: engine, awake: AwakeModel(manager: manager, hasJournal: { false }),
            monitoring: DeckMonitoringModel(interval: .milliseconds(20), refresh: {}, refreshHeavy: {}),
            popover: routedPopover
        )
        defer { routedPopover.performClose(nil); withExtendedLifetime(menuBar) {} }
        for page in [MainSelection.settings, .panel, .updates] {
            routedPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(routedPopover.isShown)
            appModel.showMainWindow(selection: page) {
                XCTAssertFalse(routedPopover.isShown, "close the tray before opening the full window")
                XCTAssertEqual(appModel.selection, page)
                mainWindow.makeKeyAndOrderFront(nil)
            }
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertFalse(routedPopover.isShown)
            XCTAssertEqual(appModel.selection, page)
            XCTAssertTrue(mainWindow.isVisible)
        }
        XCTAssertFalse(mainWindow.hidesOnDeactivate)
        let otherWindow = NSWindow(contentRect: NSRect(x: -2800, y: -2800, width: 100, height: 100),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        otherWindow.isReleasedWhenClosed = false
        defer { otherWindow.close() }
        mainWindow.makeKeyAndOrderFront(nil)
        otherWindow.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(mainWindow.isKeyWindow)
        XCTAssertTrue(mainWindow.isVisible, "settings must remain open when focus moves elsewhere")
        XCTAssertEqual(NSRunningApplication.current.activationPolicy, .regular,
                       "an open full window must keep DevDeck registered in Dock and Cmd-Tab")

        mainWindow.close()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(NSRunningApplication.current.activationPolicy, .accessory,
                       "closing the full window returns to menu bar mode without quitting")
        appModel.selection = .settings
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(NSRunningApplication.current.activationPolicy, .accessory,
                       "updating the retained SwiftUI view must not restore Dock after closing")
        appModel.showMainWindow(selection: .settings) { mainWindow.makeKeyAndOrderFront(nil) }
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(mainWindow.isVisible)
        XCTAssertEqual(NSRunningApplication.current.activationPolicy, .regular,
                       "reopening the same window must restore Cmd-Tab registration")
    }

    private func findPicker(in view: NSView) -> NSSegmentedControl? {
        if let picker = view as? NSSegmentedControl { return picker }
        return view.subviews.lazy.compactMap { self.findPicker(in: $0) }.first
    }

    private func saveSnapshot(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-stage1-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
