import XCTest
import SwiftUI
@testable import DevDeck

final class DisplayBrightnessTests: XCTestCase {
    func testSettingsDecodeOldConfigWithoutEnablingKeyboardTakeover() throws {
        let settings = try JSONDecoder().decode(DisplayBrightnessSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(settings.keyboardEnabled)
        XCTAssertFalse(settings.linkSliders)
        XCTAssertFalse(settings.linkKeys)
        XCTAssertTrue(settings.methods.isEmpty)
    }

    func testDDCRejectsCorruptWrongControlAndUnsupportedReplies() {
        func reply(_ result: UInt8 = 0, control: UInt8 = 0x10) -> [UInt8] {
            var bytes: [UInt8] = [0x6e, 0x88, 0x02, result, control, 0, 0, 100, 0, 42]
            bytes.append(bytes.reduce(0x50, ^))
            return bytes
        }
        XCTAssertEqual(BrightnessDDC.decode(reply())?.current, 42)
        XCTAssertEqual(BrightnessDDC.decode(reply())?.maximum, 100)
        XCTAssertNil(BrightnessDDC.decode(reply(1)))
        XCTAssertNil(BrightnessDDC.decode(reply(control: 0x12)))
        var corrupt = reply(); corrupt[8] ^= 1
        XCTAssertNil(BrightnessDDC.decode(corrupt))
        XCTAssertNil(BrightnessDDC.decode([]))
    }

    func testKeyboardTargetsOnlyCursorDisplayAndNeverFallsBack() {
        let displays = [BrightnessDisplay(id: "a", displayID: 1, name: "A", bounds: .init(x: 0, y: 0, width: 100, height: 100), builtIn: true, value: 0.5),
                        BrightnessDisplay(id: "b", displayID: 2, name: "B", bounds: .init(x: 100, y: 0, width: 100, height: 100), builtIn: false, value: nil)]
        XCTAssertEqual(BrightnessRouting.target(at: .init(x: 50, y: 50), displays: displays)?.id, "a")
        XCTAssertNil(BrightnessRouting.target(at: .init(x: 150, y: 50), displays: displays))
        XCTAssertNil(BrightnessRouting.target(at: .init(x: 250, y: 50), displays: displays))
    }
}

private actor BrightnessFakeProvider: DisplayBrightnessProvider {
    var value = 0.5
    var fail = false
    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay] {
        [.init(id: "a", displayID: 1, name: "A", bounds: .init(x: 0, y: 0, width: 100, height: 100), builtIn: true, value: value)]
    }
    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double {
        if fail { throw BrightnessFailure.write }
        self.value = (value * 10).rounded() / 10
        return self.value
    }
    func setFailure() { fail = true }
    func reset() async {}
}

@MainActor final class DisplayBrightnessModelTests: XCTestCase {
    func testShowsConfirmedReadbackAndRestoresValueOnFailure() async {
        let provider = BrightnessFakeProvider()
        let model = DisplayBrightnessModel(provider: provider)
        await model.refresh()
        await model.apply(id: "a", value: 0.73)
        XCTAssertEqual(model.displays.first?.value, 0.7)
        await provider.setFailure()
        await model.apply(id: "a", value: 0.2)
        XCTAssertEqual(model.displays.first?.value, 0.7)
        XCTAssertNotNil(model.errors["a"])
    }
}

private actor BrightnessLayoutProvider: DisplayBrightnessProvider {
    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay] {
        [BrightnessDisplay(id: "a", displayID: 1, name: "MacBook Pro", bounds: .zero, builtIn: true, value: 0.68),
         BrightnessDisplay(id: "b", displayID: 2, name: "Studio Display", bounds: .zero, builtIn: false, value: 0.54),
         BrightnessDisplay(id: "c", displayID: 3, name: "DELL U2723QE", bounds: .zero, builtIn: false, value: 0.42)]
    }
    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double { value }
    func reset() async {}
}

@MainActor final class BrightnessLayoutTests: XCTestCase {
    func testThreeNativeSlidersFitCompactTrayInBothLanguages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-stage4-ui")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let store = CommandStore(configURL: directory.appendingPathComponent("config.json"))
        let model = DisplayBrightnessModel(provider: BrightnessLayoutProvider())
        await model.refresh()
        let previous = LocalizationManager.shared.language
        defer { LocalizationManager.shared.language = previous }
        for language in AppLanguage.allCases {
            LocalizationManager.shared.language = language
            let hosting = NSHostingController(rootView: BrightnessSectionView(onDetails: {}).environment(store).environment(model)
                .frame(width: 380).fixedSize(horizontal: false, vertical: true))
            let window = NSWindow(contentViewController: hosting)
            window.isReleasedWhenClosed = false
            window.setFrameOrigin(.init(x: -2000, y: -2000)); window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            hosting.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.view.fittingSize.width, 380, accuracy: 1)
            XCTAssertLessThan(hosting.view.fittingSize.height, 390)
            let bitmap = try XCTUnwrap(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
            hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
            try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent("brightness-\(language.rawValue).png"))
            window.close()
        }
    }
}

private actor SlowBrightnessProvider: DisplayBrightnessProvider {
    var firstWrite: CheckedContinuation<Void, Never>?
    var writes = 0
    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay] {
        [.init(id: "a", displayID: 1, name: "A", bounds: .init(x: 0, y: 0, width: 100, height: 100), builtIn: true, value: 0.5)]
    }
    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double {
        writes += 1
        if writes == 1 { await withCheckedContinuation { firstWrite = $0 } }
        return value
    }
    func release() { firstWrite?.resume(); firstWrite = nil }
    func reset() async {}
}

extension DisplayBrightnessModelTests {
    func testRepeatedKeysAccumulateWhileHardwareWriteIsInFlight() async throws {
        let provider = SlowBrightnessProvider()
        let model = DisplayBrightnessModel(provider: provider)
        await model.refresh()
        model.handleKey(increase: true, fine: false, at: .init(x: 50, y: 50))
        for _ in 0..<100 {
            if await provider.writes == 1 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        model.handleKey(increase: true, fine: false, at: .init(x: 50, y: 50))
        await provider.release()
        for _ in 0..<100 {
            if await provider.writes == 2 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(model.displays.first?.value, 0.625, "two keys must produce two steps even during a slow DDC write")
    }
}

extension DisplayBrightnessModelTests {
    func testLinkingSlidersDoesNotLinkKeysAndKeysCanBeLinkedIndependently() async throws {
        let model = DisplayBrightnessModel(provider: BrightnessLayoutProvider())
        await model.refresh()
        var settings = DisplayBrightnessSettings()
        settings.linkSliders = true
        model.start { settings }
        defer { model.stop() }
        model.request(id: "a", value: 0.4, fromKeys: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.displays.first?.value, 0.4)
        XCTAssertEqual(model.displays.last?.value, 0.42)
        settings.linkSliders = false; settings.linkKeys = true
        model.request(id: "a", value: 0.2, fromKeys: true)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(model.displays.compactMap(\.value), [0.2, 0.2, 0.2])
    }
    func testNonFiniteRequestCannotReachHardwareOrChangeConfirmedValue() async {
        let model = DisplayBrightnessModel(provider: BrightnessFakeProvider())
        await model.refresh()
        await model.apply(id: "a", value: .nan)
        await model.apply(id: "a", value: .infinity)
        await model.apply(id: "missing", value: 0)
        XCTAssertEqual(model.displays.first?.value, 0.5)
    }
}

private actor ControlledBrightnessProvider: DisplayBrightnessProvider {
    var value = 0.5
    var holdDiscovery = false
    var holdWrite = false
    let discoveryEntered = XCTestExpectation(description: "discovery suspended")
    let writeEntered = XCTestExpectation(description: "write suspended")
    private var discoveryGate: CheckedContinuation<Void, Never>?
    private var writeGate: CheckedContinuation<Void, Never>?
    func pauseDiscovery() { holdDiscovery = true }
    func pauseWrite() { holdWrite = true }
    func releaseDiscovery() { discoveryGate?.resume(); discoveryGate = nil }
    func releaseWrite() { writeGate?.resume(); writeGate = nil }
    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay] {
        let old = value
        if holdDiscovery {
            holdDiscovery = false
            await withCheckedContinuation { discoveryGate = $0; discoveryEntered.fulfill() }
        }
        return [.init(id: "a", displayID: 1, name: "A", bounds: .init(x: 0, y: 0, width: 100, height: 100), builtIn: true,
                      value: old, method: methods["a"] ?? .hardware)]
    }
    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double {
        if holdWrite {
            holdWrite = false
            await withCheckedContinuation { writeGate = $0; writeEntered.fulfill() }
        }
        try Task.checkCancellation()
        self.value = value
        return value
    }
    func reset() async {}
}

extension DisplayBrightnessModelTests {
    func testDiscoveryFinishesBeforeQueuedWriteAndCannotReplaceNewReadback() async throws {
        let provider = ControlledBrightnessProvider()
        let model = DisplayBrightnessModel(provider: provider)
        await model.refresh()
        await provider.pauseDiscovery()
        let discovery = Task { await model.refresh() }
        await fulfillment(of: [provider.discoveryEntered], timeout: 2)
        model.request(id: "a", value: 0.8)
        try await Task.sleep(for: .milliseconds(30))
        let beforeRelease = await provider.value
        XCTAssertEqual(beforeRelease, 0.5, "no hardware write may overlap discovery")
        await provider.releaseDiscovery(); await discovery.value
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.displays.first?.value, 0.8)
        model.handleKey(increase: true, fine: false, at: .init(x: 20, y: 20))
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(model.displays.first?.value ?? 0, 0.8625, accuracy: 0.0001)
        model.stop()
    }

    func testChangingMethodCancelsWriteBeforeItReachesHardware() async throws {
        let provider = ControlledBrightnessProvider()
        let model = DisplayBrightnessModel(provider: provider)
        var settings = DisplayBrightnessSettings()
        model.start { settings }
        await model.refresh()
        await provider.pauseWrite()
        model.request(id: "a", value: 0.8)
        await fulfillment(of: [provider.writeEntered], timeout: 2)
        XCTAssertEqual(model.pending["a"], 0.8, "UI must know a write is still awaiting confirmation")
        settings.methods["a"] = .software
        await model.refresh()
        await provider.releaseWrite()
        try await Task.sleep(for: .milliseconds(30))
        let actual = await provider.value
        XCTAssertEqual(actual, 0.5, "cancelled hardware command must never be committed")
        XCTAssertTrue(model.pending.isEmpty)
        model.stop()
    }
}

extension BrightnessLayoutTests {
    func testPendingBrightnessIsVisibleUntilReadback() async throws {
        let provider = ControlledBrightnessProvider()
        let model = DisplayBrightnessModel(provider: provider)
        await model.refresh(); await provider.pauseWrite()
        model.request(id: "a", value: 0.8)
        await fulfillment(of: [provider.writeEntered], timeout: 2)
        let hosting = NSHostingController(rootView: BrightnessDisplayRow(display: try XCTUnwrap(model.displays.first))
            .environment(model).padding(16).frame(width: 380).fixedSize(horizontal: false, vertical: true))
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(.init(x: -2000, y: -2000)); window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(100))
        hosting.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.view.fittingSize.width, 380, accuracy: 1)
        XCTAssertEqual(model.displays.first?.value, 0.5, "percentage stays confirmed while slider shows requested brightness")
        XCTAssertEqual(model.pending["a"], 0.8)
        func descendants(_ view: NSView) -> [NSView] {
            [view] + view.subviews.flatMap { descendants($0) }
        }
        XCTAssertFalse(descendants(hosting.view).compactMap { $0 as? NSProgressIndicator }.isEmpty)
        let slider = try XCTUnwrap(descendants(hosting.view).compactMap { $0 as? NSSlider }.first)
        XCTAssertEqual(slider.doubleValue, 0.8, accuracy: 0.001)
        let bitmap = try XCTUnwrap(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
        hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-brightness-pending.png")
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:])).write(to: url)
        await provider.releaseWrite()
        for _ in 0..<100 {
            if model.pending.isEmpty { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertTrue(model.pending.isEmpty)
        XCTAssertEqual(model.displays.first?.value, 0.8)
        try await Task.sleep(for: .milliseconds(100))
        hosting.view.layoutSubtreeIfNeeded()
        XCTAssertTrue(descendants(hosting.view).compactMap { $0 as? NSProgressIndicator }.isEmpty)
        model.stop()
    }
}
