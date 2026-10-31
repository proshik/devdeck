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
        // Keep the three-tab minimum-width regression fixture. Additional built-in/custom
        // tabs use the existing horizontal scroller and are exercised separately.
        store.updatePanel { $0.removeSection(.clipboard) }
        let testedSections: [PanelSection] = [.environment, .monitoring, .displays]
        let manager = ProcessManager(runner: FakeCommandRunner(), vmMonitoringEnabled: { false },
                                     hostMonitoringEnabled: { false })
        let appModel = AppModel()
        let engine = EngineModel(candidates: [])
        let energy = EnergyModel(batteryProbe: FakeBatteryProbe(), energyProbe: FakeProcessEnergyProbe(),
                                 observer: FakePowerSourceObserver())
        let proxy = ProxyManager(discovering: FakeProxyDiscovering(), advertiser: FakeProxyAdvertising(),
                                 credentials: FakeProxyCredentialStore())
        let root = PopoverView()
            .environment(DeckMonitoringModel())
            .environment(store).environment(manager).environment(appModel)
            .environment(UpdateController()).environment(energy).environment(engine).environment(proxy)
            .environment(ClaudeTabsModel(defaults: AppRuntime.preferences))
            .environment(AwakeModel(manager: manager, hasJournal: { false }))
            .environment(ClipboardModel()).environment(DisplayBrightnessModel())
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
        XCTAssertEqual((0..<picker.segmentCount).map { picker.toolTip(forSegment: $0) }, testedSections.map(\.title))
        picker.selectedSegment = 2
        let action = try XCTUnwrap(picker.action)
        NSApp.sendAction(action, to: picker.target, from: picker)
        XCTAssertEqual(appModel.panelSection, .displays)
        XCTAssertEqual(try ConfigCodec.decode(Data(contentsOf: directory.appendingPathComponent("config.json"))).panel.lastSection,
                       "displays", "the native tab action must save the last section")
        store.updatePanel {
            $0.moveSection(.displays, before: .environment)
            $0.setSectionVisible(.monitoring, false)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual((0..<picker.segmentCount).map { picker.label(forSegment: $0) }, [L10n.deckDisplays, L10n.deckEnvironment])
        picker.selectedSegment = 1
        NSApp.sendAction(action, to: picker.target, from: picker)
        XCTAssertEqual(appModel.panelSection, .environment, "selection must follow reordered visible IDs, not enum indexes")
        store.updatePanel {
            $0.setSectionVisible(.environment, false)
            $0.setSectionVisible(.displays, false)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(findPicker(in: hosting.view), "an empty panel must offer configuration instead of unavailable tabs")
        XCTAssertLessThan(hosting.view.fittingSize.height, 250)
        try saveSnapshot(hosting.view, name: "panel-all-hidden")
        store.updatePanel { $0 = .standard; $0.removeSection(.clipboard) }
        try await Task.sleep(for: .milliseconds(100))
        let currentPicker = try XCTUnwrap(findPicker(in: hosting.view))
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
                for section in testedSections {
                    appModel.panelSection = section
                    try await Task.sleep(for: .milliseconds(100))
                    hosting.view.layoutSubtreeIfNeeded()
                    XCTAssertEqual((0..<currentPicker.segmentCount).map { currentPicker.toolTip(forSegment: $0) }, testedSections.map(\.title))
                    XCTAssertLessThan(hosting.view.fittingSize.height, 700)
                    XCTAssertEqual(currentPicker.selectedSegment, testedSections.firstIndex(of: section))
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
        XCTAssertLessThan(popoverContent.bounds.height, 700, "all visible monitoring modules must fit the content cap")
        popover.performClose(nil)

        let mainRoot = MainWindowView()
            .environment(store).environment(manager).environment(appModel)
            .environment(UpdateController()).environment(energy).environment(engine).environment(proxy)
            .environment(ClaudeTabsModel(defaults: AppRuntime.preferences))
            .environment(AwakeModel(manager: manager, hasJournal: { false }))
            .environment(ClipboardModel()).environment(DisplayBrightnessModel())
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
        for selection in [MainSelection.settings, .commands, .panel, .updates, .monitoring, .containers, .energy, .awake, .clipboard, .displays, .ports, .proxy, .claudeTabs, .cleanup] {
            appModel.selection = selection
            mainWindow.setContentSize(NSSize(width: mainHosting.view.fittingSize.width, height: 580))
            try await Task.sleep(for: .milliseconds(100))
            mainHosting.view.layoutSubtreeIfNeeded()
            XCTAssertGreaterThanOrEqual(mainHosting.view.bounds.width, 860)
            try saveSnapshot(mainHosting.view, name: "window-\(selection)")
            if selection == .panel {
                // The default tabs must be fully usable at the window's actual minimum,
                // not merely aligned in a row that extends outside its viewport.
                let minimumWidth = mainHosting.view.fittingSize.width
                for width in [minimumWidth, 1080.0] {
                    mainWindow.setContentSize(NSSize(width: width, height: 580))
                    try await Task.sleep(for: .milliseconds(100))
                    mainHosting.view.layoutSubtreeIfNeeded()
                    let headers = try testedSections.map { section in
                        let checkbox = try XCTUnwrap(findVisibilityCheckbox(in: mainHosting.view,
                                                                           id: "panel-section-\(section.rawValue)"))
                        return checkbox.convert(checkbox.bounds, to: mainHosting.view)
                    }
                    for rect in headers.dropFirst() {
                        XCTAssertEqual(rect.midY, headers[0].midY, accuracy: 1, "tabs must not wrap onto a second row")
                    }
                    for section in testedSections {
                        let checkbox = try XCTUnwrap(findVisibilityCheckbox(in: mainHosting.view,
                                                                           id: "panel-section-\(section.rawValue)"))
                        let controlRect = checkbox.convert(checkbox.bounds, to: mainHosting.view)
                        XCTAssertGreaterThanOrEqual(controlRect.minX, mainHosting.view.bounds.minX)
                        XCTAssertLessThanOrEqual(controlRect.maxX + 24, mainHosting.view.bounds.maxX,
                                      "all default tab controls must be visible at the minimum width (\(width))")
                    }
                    for module in PanelModuleID.allCases.filter { $0 != .clipboard } {
                        let checkbox = try XCTUnwrap(findVisibilityCheckbox(in: mainHosting.view,
                                                                           id: "panel-module-\(module.rawValue)"))
                        let rect = checkbox.convert(checkbox.bounds, to: mainHosting.view)
                        XCTAssertLessThanOrEqual(rect.maxX, mainHosting.view.bounds.maxX - 20,
                                                 "module visibility must remain reachable without horizontal scrolling")
                    }
                    for layout in store.config.panel.sections {
                        let header = try XCTUnwrap(findVisibilityCheckbox(in: mainHosting.view,
                                                                         id: "panel-section-\(layout.id)"))
                        let headerRect = header.convert(header.bounds, to: mainHosting.view)
                        for placement in layout.modules {
                            let checkbox = try XCTUnwrap(findVisibilityCheckbox(in: mainHosting.view,
                                                                               id: "panel-module-\(placement.id)"))
                            let rect = checkbox.convert(checkbox.bounds, to: mainHosting.view)
                            XCTAssertEqual(rect.midX, headerRect.midX, accuracy: 1,
                                           "tab and module visibility controls must share one column")
                        }
                    }
                    XCTAssertLessThan(headers[0].midX, headers[1].midX)
                    XCTAssertLessThan(headers[1].midX, headers[2].midX)
                    try saveSnapshot(mainHosting.view, name: "window-panel-\(Int(width))")
                }
                let settings = store.config.settings
                let toggle = try XCTUnwrap(findVisibilityCheckbox(in: mainHosting.view, id: "panel-module-proxy"))
                XCTAssertEqual(toggle.accessibilityLabel(), L10n.panelShowModule(PanelModuleID.proxy.title))
                _ = toggle.accessibilityPerformPress()
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertFalse(store.config.panel.isShown(.proxy), "the actual settings checkbox must hide the block")
                XCTAssertEqual(store.config.settings, settings, "visibility must not change collection or process settings")
                let newToggle = try XCTUnwrap(findVisibilityCheckbox(in: mainHosting.view, id: "panel-module-proxy"))
                _ = newToggle.accessibilityPerformPress()
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertTrue(store.config.panel.isShown(.proxy))

                // Custom names and reordered IDs must drive the actual native tray control.
                var custom: PanelSection!
                store.updatePanel {
                    custom = $0.addSection(name: "Focused tools", icon: "star")
                    $0.moveModule(.proxy, to: custom)
                    $0.removeModule(.awake)
                    $0.removeModule(.brightness)
                    $0.moveSection(custom, before: .monitoring)
                }
                try await Task.sleep(for: .milliseconds(150))
                let customPicker = try XCTUnwrap(findPicker(in: hosting.view))
                XCTAssertEqual((0..<customPicker.segmentCount).map { customPicker.label(forSegment: $0) },
                               [L10n.deckEnvironment, "Focused tools", L10n.deckMonitoring])
                customPicker.selectedSegment = 1
                NSApp.sendAction(try XCTUnwrap(customPicker.action), to: customPicker.target, from: customPicker)
                XCTAssertEqual(appModel.panelSection, custom)
                XCTAssertEqual(try ConfigCodec.decode(Data(contentsOf: directory.appendingPathComponent("config.json"))).panel.lastSection,
                               custom.rawValue)
                store.updatePanel { $0.renameSection(custom, name: "Renamed tools", icon: "network") }
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(customPicker.label(forSegment: 1), "Renamed tools")
                XCTAssertEqual(customPicker.selectedSegment, 1, "renaming must preserve the selected identity")
                try saveSnapshot(mainHosting.view, name: "window-panel-custom-catalogue")
                store.updatePanel { $0.removeSection(custom) }
                try await Task.sleep(for: .milliseconds(100))
                XCTAssertEqual(customPicker.segmentCount, 2)
                XCTAssertNotEqual(appModel.panelSection, custom, "removing the selected tab must select an available tab")
                store.updatePanel { $0.restoreStandardLayout() }
                try await Task.sleep(for: .milliseconds(100))
            }
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
        store.updatePanel {
            $0.rememberLastSection = false
            $0.initialSection = "displays"
            $0.lastSection = "monitoring"
        }
        appModel.panelSection = .monitoring
        routedPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertTrue(routedPopover.isShown)
        XCTAssertEqual(appModel.panelSection, .displays, "opening must use the configured initial section")
        routedPopover.performClose(nil)
        try await Task.sleep(for: .milliseconds(150))
        store.updatePanel { $0.rememberLastSection = true; $0.lastSection = "environment" }
        routedPopover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .minY)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(appModel.panelSection, .environment, "reopening must restore the saved last section")
        routedPopover.performClose(nil)
        try await Task.sleep(for: .milliseconds(150))
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

    private func findVisibilityCheckbox(in view: NSView, id: String) -> NSButton? {
        if let control = view as? NSButton, control.accessibilityIdentifier() == id { return control }
        return view.subviews.lazy.compactMap { self.findVisibilityCheckbox(in: $0, id: id) }.first
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
