import AppKit
import SwiftUI
import XCTest
@testable import DevDeck

@MainActor final class ClipboardLayoutTests: XCTestCase {
    func testNativeClipboardHistoryFitsTrayAndMinimumWindowInBothLanguages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommandStore(configURL: directory.appendingPathComponent("config.json"))
        try store.save(.empty)
        store.updateClipboard { $0.enabled = true }
        let board = NSPasteboard(name: .init("DevDeck-layout-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let model = ClipboardModel(history: ClipboardHistory(storage: ClipboardFileStorage(directory: directory.appendingPathComponent("Clipboard"))),
                                   pasteboard: SystemClipboardPasteboard(pasteboard: board))
        await model.synchronize(store.config.settings.clipboard)
        for text in ["kubectl get pods -n development", "http://127.0.0.1:8080", "Текст на русском\nи вторая строка", "{\"routeThroughProxy\": true}", "A very long line " + String(repeating: "text ", count: 100), "git status", "swift build", "just test"] {
            board.clearContents(); board.setString(text, forType: .string)
            await model.poll()
        }
        let first = try XCTUnwrap(model.entries.last)
        await model.setPinned(first)
        let previousLanguage = LocalizationManager.shared.language
        let previousAppearance = NSApp.appearance
        defer { LocalizationManager.shared.language = previousLanguage; NSApp.appearance = previousAppearance }
        for language in AppLanguage.allCases {
            LocalizationManager.shared.language = language
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                let tray = NSHostingController(rootView: ClipboardSectionView(onDetails: {})
                    .environment(store).environment(model).labelStyle(DeckLabelStyle())
                    .frame(width: 380).fixedSize(horizontal: false, vertical: true))
                let trayWindow = NSWindow(contentViewController: tray)
                trayWindow.isReleasedWhenClosed = false; trayWindow.setFrameOrigin(NSPoint(x: -2000, y: -2000)); trayWindow.orderFront(nil)
                try await Task.sleep(for: .milliseconds(100)); tray.view.layoutSubtreeIfNeeded()
                XCTAssertEqual(tray.view.fittingSize.width, 380, accuracy: 1)
                XCTAssertLessThan(tray.view.fittingSize.height, 430, "six compact rows must not make a full-height tray")
                try snapshot(tray.view, name: "clipboard-tray-\(language.rawValue)-\(appearance.rawValue)")
                trayWindow.close()

                let main = NSHostingController(rootView: ClipboardView().environment(store).environment(model)
                    .frame(width: 740, height: 580))
                let mainWindow = NSWindow(contentViewController: main)
                mainWindow.isReleasedWhenClosed = false; mainWindow.setFrameOrigin(NSPoint(x: -2000, y: -2000)); mainWindow.orderFront(nil)
                try await Task.sleep(for: .milliseconds(100)); main.view.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(main.view.fittingSize.width, 740)
                try snapshot(main.view, name: "clipboard-history-\(language.rawValue)-\(appearance.rawValue)")
                mainWindow.close()

                let settings = NSHostingController(rootView: ClipboardSettingsView().environment(store).environment(model)
                    .frame(width: 740, height: 580))
                let settingsWindow = NSWindow(contentViewController: settings)
                settingsWindow.isReleasedWhenClosed = false; settingsWindow.setFrameOrigin(NSPoint(x: -2000, y: -2000)); settingsWindow.orderFront(nil)
                try await Task.sleep(for: .milliseconds(100)); settings.view.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(settings.view.fittingSize.width, 740)
                try snapshot(settings.view, name: "clipboard-settings-\(language.rawValue)-\(appearance.rawValue)")
                settingsWindow.close()
            }
        }
        model.copy(first)
        XCTAssertEqual(board.string(forType: .string), "kubectl get pods -n development", "real AppKit copy-back must preserve the complete text")
        await model.poll()
        XCTAssertEqual(model.entries.count, 8, "copy-back must not enter the history again")
    }
    private func snapshot(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-stage3-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}

extension ClipboardLayoutTests {
    func testFourthBuiltinTabRoutesNativeSelectionAndPersistsWithCompactPopover() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommandStore(configURL: directory.appendingPathComponent("config.json"))
        try store.save(.empty)
        let appModel = AppModel()
        let manager = ProcessManager(runner: FakeCommandRunner(), vmMonitoringEnabled: { false }, hostMonitoringEnabled: { false })
        let board = NSPasteboard(name: .init("DevDeck-picker-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let clipboard = ClipboardModel(history: ClipboardHistory(storage: ClipboardFileStorage(directory: directory.appendingPathComponent("Clipboard"))), pasteboard: SystemClipboardPasteboard(pasteboard: board))
        let root = PopoverView().environment(store).environment(manager).environment(appModel)
            .environment(UpdateController())
            .environment(ProxyManager(discovering: FakeProxyDiscovering(), advertiser: FakeProxyAdvertising(), credentials: FakeProxyCredentialStore()))
            .environment(ClaudeTabsModel(defaults: AppRuntime.preferences))
            .environment(EnergyModel(batteryProbe: FakeBatteryProbe(), energyProbe: FakeProcessEnergyProbe(), observer: FakePowerSourceObserver()))
            .environment(EngineModel(candidates: []))
            .environment(AwakeModel(manager: manager, hasJournal: { false })).environment(clipboard)
            .defaultAppStorage(AppRuntime.preferences)
        let hosting = NSHostingController(rootView: root)
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false; window.setFrameOrigin(NSPoint(x: -2000, y: -2000)); window.orderFront(nil)
        defer { window.close() }
        let previousLanguage = LocalizationManager.shared.language
        defer { LocalizationManager.shared.language = previousLanguage }
        for language in AppLanguage.allCases {
            LocalizationManager.shared.language = language
            try await Task.sleep(for: .milliseconds(100))
            hosting.view.layoutSubtreeIfNeeded()
            let picker = try XCTUnwrap(nativePicker(hosting.view))
            XCTAssertEqual(picker.segmentCount, 4)
            XCTAssertEqual(picker.toolTip(forSegment: 3), L10n.clipboardTab)
            picker.selectedSegment = 3
            NSApp.sendAction(try XCTUnwrap(picker.action), to: picker.target, from: picker)
            try await Task.sleep(for: .milliseconds(100))
            hosting.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(appModel.panelSection, .clipboard)
            XCTAssertEqual(try ConfigCodec.decode(Data(contentsOf: directory.appendingPathComponent("config.json"))).panel.lastSection, "clipboard")
            XCTAssertEqual(hosting.view.fittingSize.width, 380, accuracy: 1)
            XCTAssertLessThan(hosting.view.fittingSize.height, 300)
            XCTAssertFalse(store.config.settings.clipboard.enabled, "showing the tab must not implicitly enable collection")
            try snapshot(hosting.view, name: "clipboard-full-popover-\(language.rawValue)")
        }
    }
    private func nativePicker(_ view: NSView) -> NSSegmentedControl? {
        if let picker = view as? NSSegmentedControl { return picker }
        return view.subviews.lazy.compactMap { self.nativePicker($0) }.first
    }
}

extension ClipboardLayoutTests {
    func testMixedHistoryFilterAndPreviewsFitCompactTrayInBothLanguages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommandStore(configURL: directory.appendingPathComponent("config.json")); try store.save(.empty)
        store.updateClipboard { $0.enabled = true; $0.pasteEnabled = true }
        let board = NSPasteboard(name: .init("DevDeck-stage5-layout-\(UUID())")); defer { board.releaseGlobally() }
        let adapter = SystemClipboardPasteboard(pasteboard: board)
        let model = ClipboardModel(history: ClipboardHistory(storage: ClipboardFileStorage(directory: directory.appendingPathComponent("Clipboard"))), pasteboard: adapter)
        await model.synchronize(store.config.settings.clipboard)
        let image = try XCTUnwrap(ClipboardImageProcessor.inspect(clipboardTestImage(), type: "public.png"))
        let tiff = try XCTUnwrap(ClipboardImageProcessor.inspect(clipboardTestImage(type: "public.tiff"), type: "public.tiff"))
        let file = directory.appendingPathComponent("example.txt"); try Data("example".utf8).write(to: file)
        let contents: [ClipboardContent] = [.text("kubectl get pods"), .image(image), .files([file, directory.appendingPathComponent("missing.txt")]), .text(String(repeating: "Long text ", count: 100)), .image(tiff), .text("Last text")]
        for content in contents {
            if case .files = content {
                // Capture references even when files have become unavailable.
                let items = [file, directory.appendingPathComponent("missing.txt")].map { url in
                    let item = NSPasteboardItem(); item.setString(url.absoluteString, forType: .fileURL); return item
                }
                board.clearContents(); board.writeObjects(items)
            } else { XCTAssertNotNil(adapter.write(.init(content: content))) }
            await model.poll()
        }
        XCTAssertEqual(model.entries.count, 6)
        let previousLanguage = LocalizationManager.shared.language
        let previousAppearance = NSApp.appearance
        defer { LocalizationManager.shared.language = previousLanguage; NSApp.appearance = previousAppearance }
        func popups(_ view: NSView) -> [NSPopUpButton] {
            (view as? NSPopUpButton).map { [$0] } ?? view.subviews.flatMap { popups($0) }
        }
        for language in AppLanguage.allCases {
            LocalizationManager.shared.language = language
            for appearance in [NSAppearance.Name.aqua, .darkAqua] {
                NSApp.appearance = NSAppearance(named: appearance)
                let tray = NSHostingController(rootView: ClipboardSectionView(onDetails: {}).environment(store).environment(model)
                    .frame(width: 380).fixedSize(horizontal: false, vertical: true))
                let window = NSWindow(contentViewController: tray); window.isReleasedWhenClosed = false
                window.setFrameOrigin(.init(x: -2000, y: -2000)); window.orderFront(nil)
                try await Task.sleep(for: .milliseconds(150)); tray.view.layoutSubtreeIfNeeded()
                XCTAssertEqual(tray.view.fittingSize.width, 380, accuracy: 1)
                XCTAssertLessThan(tray.view.fittingSize.height, 450)
                let fullHeight = tray.view.fittingSize.height
                try snapshot(tray.view, name: "stage5-mixed-tray-\(language.rawValue)-\(appearance.rawValue)")
                let picker = try XCTUnwrap(popups(tray.view).first)
                XCTAssertEqual(picker.numberOfItems, 4)
                let item = try XCTUnwrap(picker.item(at: 3))
                NSApp.sendAction(try XCTUnwrap(item.action), to: item.target, from: item)
                try await Task.sleep(for: .milliseconds(100)); tray.view.layoutSubtreeIfNeeded()
                XCTAssertLessThan(tray.view.fittingSize.height, fullHeight - 100, "native type selection must really filter the rendered rows")
                window.close()
                let main = NSHostingController(rootView: ClipboardView().environment(store).environment(model).frame(width: 740, height: 580))
                let mainWindow = NSWindow(contentViewController: main); mainWindow.isReleasedWhenClosed = false
                mainWindow.setFrameOrigin(.init(x: -2000, y: -2000)); mainWindow.orderFront(nil)
                try await Task.sleep(for: .milliseconds(150)); main.view.layoutSubtreeIfNeeded()
                XCTAssertLessThanOrEqual(main.view.fittingSize.width, 740)
                try snapshot(main.view, name: "stage5-mixed-history-\(language.rawValue)-\(appearance.rawValue)")
                mainWindow.close()
            }
        }
        for kind in [ClipboardContent.Kind.image, .files] {
            let entry = try XCTUnwrap(model.entries.first(where: { $0.kind == kind }))
            let detail = NSHostingController(rootView: ClipboardContentDetail(entry: entry).environment(model).padding(16).frame(width: 300, height: 400))
            let window = NSWindow(contentViewController: detail); window.isReleasedWhenClosed = false
            window.setFrameOrigin(.init(x: -2000, y: -2000)); window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(200)); detail.view.layoutSubtreeIfNeeded()
            try snapshot(detail.view, name: "stage5-detail-\(kind.rawValue)")
            window.close()
        }
    }
}
