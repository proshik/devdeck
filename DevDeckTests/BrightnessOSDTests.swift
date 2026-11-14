import XCTest
import AppKit
@testable import DevDeck

@MainActor private final class OSDRecorder: BrightnessOSDPresenting {
    var shown: [(String, Double)] = []
    var visible: String?
    func show(display: BrightnessDisplay, value: Double) { shown.append((display.id, value)); visible = display.id }
    func hide() { visible = nil }
}

private actor OSDProvider: DisplayBrightnessProvider {
    enum Outcome: Sendable { case value(Double), failure, mismatch(Double) }
    var screens = [BrightnessDisplay(id: "a", displayID: 1, name: "Laptop", bounds: CGRect(x: 0, y: 0, width: 100, height: 100), builtIn: true, value: 0.5),
                   BrightnessDisplay(id: "b", displayID: 2, name: "Dell", bounds: CGRect(x: 100, y: 0, width: 100, height: 100), builtIn: false, value: 0.6)]
    var calls: [(String, Double)] = []
    private var gates: [CheckedContinuation<Outcome, Never>] = []
    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay] { screens }
    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double {
        calls.append((display.id, value))
        // Deliberately ignore cancellation: model must also reject stale publication.
        let outcome = await withCheckedContinuation { gates.append($0) }
        switch outcome {
        case .value(let actual): return actual
        case .failure: throw BrightnessFailure.write
        case .mismatch(let actual): throw BrightnessFailure.unconfirmed(actual: actual)
        }
    }
    func resolve(_ outcome: Outcome) { gates.removeFirst().resume(returning: outcome) }
    func disconnect() { screens.removeAll() }
    func reset() async {}
}

@MainActor final class BrightnessOSDModelTests: XCTestCase {
    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("condition did not settle", file: file, line: line)
    }
    func testOnlyConfirmedKeyReadbackShowsOSDNotDiscoveryOrSlider() async {
        let provider = OSDProvider(), osd = OSDRecorder()
        let model = DisplayBrightnessModel(provider: provider, osd: osd)
        await model.refresh(); XCTAssertTrue(osd.shown.isEmpty)
        model.request(id: "a", value: 0.7)
        await eventually { await provider.calls.count == 1 }
        await provider.resolve(.value(0.68))
        await eventually { model.pending.isEmpty }
        XCTAssertTrue(osd.shown.isEmpty)
        model.handleKey(increase: false, fine: false, at: CGPoint(x: 150, y: 50))
        await eventually { await provider.calls.count == 2 }
        XCTAssertTrue(osd.shown.isEmpty, "requested brightness is not confirmation")
        await provider.resolve(.value(0.54))
        await eventually { model.pending.isEmpty }
        XCTAssertEqual(osd.shown.map(\.0), ["b"])
        XCTAssertEqual(osd.shown.last?.1, 0.54)
        model.stop()
    }
    func testRepeatedKeysCoalesceAndNeverPublishSupersededReadback() async {
        let provider = OSDProvider(), osd = OSDRecorder()
        let model = DisplayBrightnessModel(provider: provider, osd: osd)
        await model.refresh()
        model.handleKey(increase: true, fine: false, at: CGPoint(x: 50, y: 50))
        await eventually { await provider.calls.count == 1 }
        model.handleKey(increase: true, fine: false, at: CGPoint(x: 50, y: 50))
        model.handleKey(increase: true, fine: false, at: CGPoint(x: 50, y: 50))
        await provider.resolve(.value(0.56))
        await eventually { await provider.calls.count == 2 }
        XCTAssertTrue(osd.shown.isEmpty)
        let calls = await provider.calls
        XCTAssertEqual(calls.last?.1, 0.6875)
        await provider.resolve(.value(0.69))
        await eventually { model.pending.isEmpty }
        XCTAssertEqual(osd.shown.map(\.1), [0.69])
        model.stop()
    }
    func testCursorTargetChangeCannotShowEarlierDisplay() async {
        let provider = OSDProvider(), osd = OSDRecorder()
        let model = DisplayBrightnessModel(provider: provider, osd: osd)
        await model.refresh()
        model.handleKey(increase: true, fine: false, at: CGPoint(x: 50, y: 50))
        await eventually { await provider.calls.count == 1 }
        model.handleKey(increase: false, fine: false, at: CGPoint(x: 150, y: 50))
        await provider.resolve(.value(0.56))
        await eventually { await provider.calls.count == 2 }
        XCTAssertTrue(osd.shown.isEmpty)
        await provider.resolve(.value(0.54))
        await eventually { model.pending.isEmpty }
        XCTAssertEqual(osd.shown.map(\.0), ["b"])
        model.stop()
    }
    func testLinkedKeysShowOnlyCursorTargetAndLinkedFailureHidesOSD() async {
        for failLinked in [false, true] {
            let provider = OSDProvider(), osd = OSDRecorder()
            let model = DisplayBrightnessModel(provider: provider, osd: osd)
            var settings = DisplayBrightnessSettings(); settings.linkKeys = true
            model.start { settings }; await model.refresh()
            await eventually { !model.refreshing && !model.displays.isEmpty }
            model.handleKey(increase: true, fine: false, at: CGPoint(x: 150, y: 50))
            for count in 1...2 {
                await eventually { await provider.calls.count == count }
                let id = await provider.calls.last?.0
                await provider.resolve(failLinked && id == "a" ? .failure : .value(id == "b" ? 0.66 : 0.65))
            }
            await eventually { model.pending.isEmpty }
            XCTAssertTrue(osd.shown.allSatisfy { $0.0 == "b" && $0.1 == 0.66 })
            if failLinked { XCTAssertNil(osd.visible) }
            else { XCTAssertEqual(osd.visible, "b"); XCTAssertEqual(osd.shown.count, 1) }
            model.stop()
        }
    }
    func testFailureAndUnconfirmedValueHideRatherThanShowRequestedOrObservedValue() async {
        for outcome: OSDProvider.Outcome in [.failure, .mismatch(0.99), .value(.nan)] {
            let provider = OSDProvider(), osd = OSDRecorder()
            let model = DisplayBrightnessModel(provider: provider, osd: osd)
            await model.refresh()
            model.handleKey(increase: true, fine: false, at: CGPoint(x: 50, y: 50))
            await eventually { await provider.calls.count == 1 }
            await provider.resolve(.value(0.56))
            await eventually { model.pending.isEmpty }
            XCTAssertEqual(osd.visible, "a")
            model.handleKey(increase: true, fine: false, at: CGPoint(x: 50, y: 50))
            await eventually { await provider.calls.count == 2 }
            await provider.resolve(outcome)
            await eventually { model.pending.isEmpty }
            XCTAssertNil(osd.visible); XCTAssertEqual(osd.shown.count, 1)
            XCTAssertNotNil(model.errors["a"])
            model.stop()
        }
    }
    func testUnavailableTargetAndDisconnectClearVisibleOSD() async {
        let provider = OSDProvider(), osd = OSDRecorder()
        let model = DisplayBrightnessModel(provider: provider, osd: osd)
        await model.refresh()
        model.handleKey(increase: true, fine: false, at: CGPoint(x: 50, y: 50))
        await eventually { await provider.calls.count == 1 }; await provider.resolve(.value(0.56))
        await eventually { model.pending.isEmpty }
        model.handleKey(increase: true, fine: false, at: CGPoint(x: 300, y: 50))
        XCTAssertNil(osd.visible)
        model.handleKey(increase: true, fine: false, at: CGPoint(x: 50, y: 50))
        await eventually { await provider.calls.count == 2 }; await provider.resolve(.value(0.62))
        await eventually { model.pending.isEmpty }
        await provider.disconnect(); await model.refresh()
        XCTAssertNil(osd.visible)
        model.stop()
    }
    func testStopAndMethodGenerationDiscardInFlightKeyConfirmation() async {
        for stop in [true, false] {
            let provider = OSDProvider(), osd = OSDRecorder()
            let model = DisplayBrightnessModel(provider: provider, osd: osd)
            var settings = DisplayBrightnessSettings()
            model.start { settings }; await model.refresh()
            await eventually { !model.refreshing && !model.displays.isEmpty }
            model.handleKey(increase: true, fine: false, at: CGPoint(x: 50, y: 50))
            await eventually { await provider.calls.count == 1 }
            if stop { model.stop() }
            else { settings.methods["a"] = .software; await model.refresh() }
            await provider.resolve(.value(0.56))
            await eventually { !model.pending.keys.contains("a") }
            // Let the held collector actually return to the model.
            for _ in 0..<10 { await Task.yield() }
            XCTAssertTrue(osd.shown.isEmpty); XCTAssertNil(osd.visible)
            model.stop()
        }
    }
    func testSleepScreenChangeAndStopClearConfirmedOSD() async {
        for event in ["sleep", "screens", "stop"] {
            let provider = OSDProvider(), osd = OSDRecorder()
            let model = DisplayBrightnessModel(provider: provider, osd: osd)
            model.start { DisplayBrightnessSettings() }; await model.refresh()
            await eventually { !model.refreshing && !model.displays.isEmpty }
            model.handleKey(increase: true, fine: false, at: CGPoint(x: 50, y: 50))
            await eventually { await provider.calls.count == 1 }; await provider.resolve(.value(0.56))
            await eventually { model.pending.isEmpty }
            XCTAssertEqual(osd.visible, "a")
            switch event {
            case "sleep": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            case "screens": NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            default: model.stop()
            }
            await eventually { osd.visible == nil }
            model.stop()
        }
    }
    func testSameClampedValueStillConfirmsLatestKeyAndSliderSupersedesKeyOSD() async {
        let provider = OSDProvider(), osd = OSDRecorder()
        let model = DisplayBrightnessModel(provider: provider, osd: osd)
        await model.refresh()
        model.request(id: "a", value: 1, fromKeys: true)
        await eventually { await provider.calls.count == 1 }
        model.request(id: "a", value: 1, fromKeys: true)
        await provider.resolve(.value(1))
        await eventually { await provider.calls.count == 2 }
        XCTAssertTrue(osd.shown.isEmpty)
        await provider.resolve(.value(1)); await eventually { model.pending.isEmpty }
        XCTAssertEqual(osd.shown.count, 1)
        model.request(id: "a", value: 0.9, fromKeys: true)
        await eventually { await provider.calls.count == 3 }
        model.request(id: "a", value: 0.8)
        XCTAssertNil(osd.visible)
        await provider.resolve(.value(0.9))
        await eventually { await provider.calls.count == 4 }
        await provider.resolve(.value(0.8)); await eventually { model.pending.isEmpty }
        XCTAssertEqual(osd.shown.count, 1)
        model.stop()
    }
}

@MainActor private final class OSDClock {
    var waits: [(Duration, CheckedContinuation<Void, Error>)] = []
    func sleep(_ duration: Duration) async throws { try await withCheckedThrowingContinuation { waits.append((duration, $0)) } }
    func advance() { waits.removeFirst().1.resume() }
    func finish() { let remaining = waits; waits = []; for wait in remaining { wait.1.resume(throwing: CancellationError()) } }
}

@MainActor final class BrightnessOSDPanelTests: XCTestCase {
    private let display = BrightnessDisplay(id: "fixture", displayID: 0, name: "DELL U2720Q", bounds: .zero, builtIn: false, value: 0.5)
    func testOneClickThroughNonactivatingPanelReusesContentAndCleansUp() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let controller = BrightnessOSDController(screen: { _ in screen })
        let window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.makeKeyAndOrderFront(nil)
        defer { controller.hide(); window.close() }
        let key = NSApp.keyWindow, frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier
        controller.show(display: display, value: 0.54)
        let panel = try XCTUnwrap(controller.panel)
        XCTAssertTrue(panel.isVisible); XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.collectionBehavior.contains([.canJoinAllSpaces, .fullScreenAuxiliary]))
        XCTAssertEqual(NSApp.keyWindow, key)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, frontmost)
        XCTAssertTrue(screen.visibleFrame.contains(panel.frame))
        controller.show(display: display, value: 0.63)
        XCTAssertTrue(controller.panel === panel); XCTAssertEqual(controller.content?.value, 0.63)
        controller.hide()
        XCTAssertNil(controller.panel); XCTAssertNil(controller.content); XCTAssertFalse(panel.isVisible)
    }
    func testTopRightPlacementKeepsSafeInsetOnTargetVisibleFrameIncludingNegativeOrigins() {
        for visible in [CGRect(x: -2560, y: -300, width: 2560, height: 1400), CGRect(x: 0, y: 25, width: 1512, height: 900), CGRect(x: 100, y: 200, width: 180, height: 100)] {
            let frame = BrightnessOSDController.frame(in: visible)
            XCTAssertTrue(visible.contains(frame))
            XCTAssertEqual(frame.maxX, visible.maxX - 16)
            XCTAssertEqual(frame.maxY, visible.maxY - 16)
            XCTAssertLessThanOrEqual(frame.width, 320)
            XCTAssertLessThanOrEqual(frame.height, 64)
        }
    }
    func testMissingScreenOrInvalidValueCannotLeavePanelVisible() throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var available = true
        let controller = BrightnessOSDController(screen: { _ in available ? screen : nil })
        defer { controller.hide() }
        for value in [Double.nan, .infinity, -0.1, 1.1] {
            controller.show(display: display, value: 0.5)
            controller.show(display: display, value: value)
            XCTAssertNil(controller.panel)
        }
        controller.show(display: display, value: 0.5); available = false
        controller.show(display: display, value: 0.6); XCTAssertNil(controller.panel)
    }
    func testLatestConfirmationRestartsHideDeadlineAndOldFadeCannotHideNewValue() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first), clock = OSDClock()
        let controller = BrightnessOSDController(screen: { _ in screen }, wait: clock.sleep)
        defer { controller.hide(); clock.finish() }
        controller.show(display: display, value: 0.5)
        for _ in 0..<10 { await Task.yield() }
        controller.show(display: display, value: 0.6)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(clock.waits.map(\.0), [.seconds(1), .seconds(1)])
        clock.advance() // Old cancelled deadline.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.content?.value, 0.6)
        clock.advance() // Current deadline starts fade.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(clock.waits.first?.0, .milliseconds(180))
        controller.show(display: display, value: 0.7)
        for _ in 0..<10 { await Task.yield() }
        clock.advance() // Old fade completion must not close current panel.
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(controller.content?.value, 0.7); XCTAssertNotNil(controller.panel)
        clock.advance()
        for _ in 0..<10 { await Task.yield() }
        clock.advance()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(controller.panel)
    }
    func testReleasingControllerCannotLeaveAnOrphanPanel() async throws {
        let screen = try XCTUnwrap(NSScreen.screens.first)
        var controller: BrightnessOSDController? = BrightnessOSDController(screen: { _ in screen })
        controller?.show(display: display, value: 0.5)
        let panel = try XCTUnwrap(controller?.panel)
        weak var released = controller
        controller = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(released); XCTAssertFalse(panel.isVisible)
    }
}
