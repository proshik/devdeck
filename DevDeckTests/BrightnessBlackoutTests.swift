import XCTest
import AppKit
@testable import DevDeck

private actor ZeroProvider: DisplayBrightnessProvider {
    var values: [String: Double] = ["a": 0.5, "b": 0.6]
    var calls: [(String, Double)] = []
    var hold = false, fail = false
    private var gate: CheckedContinuation<Void, Never>?
    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay] {
        ["a", "b"].compactMap { id in values[id].map { value in
            BrightnessDisplay(id: id, displayID: id == "a" ? 1 : 2, name: id,
                bounds: CGRect(x: id == "a" ? 0 : 100, y: 0, width: 100, height: 100),
                builtIn: id == "a", value: value, method: methods[id] ?? .hardware)
        } }
    }
    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double {
        calls.append((display.id, value))
        if hold { hold = false; await withCheckedContinuation { gate = $0 } }
        try Task.checkCancellation()
        if fail { throw BrightnessFailure.write }
        values[display.id] = value
        return value
    }
    func configure(hold: Bool = false, fail: Bool = false) { self.hold = hold; self.fail = fail }
    func release() { gate?.resume(); gate = nil }
    func disconnect() { values = [:] }
    func reset() async {}
}

@MainActor private final class ZeroOSD: BrightnessOSDPresenting {
    var shown: [Double] = []
    var visible = false
    func show(display: BrightnessDisplay, value: Double) { shown.append(value); visible = true }
    func hide() { visible = false }
}

@MainActor final class BrightnessBlackoutTests: XCTestCase {
    // Native panels are restricted to tiny OFFSCREEN fixture rectangles, never physical monitors.
    private func controller() -> BrightnessBlackoutController {
        BrightnessBlackoutController(target: { display in
            BrightnessBlackoutTarget(id: display.id, displayID: display.displayID,
                frame: CGRect(x: -4000, y: -4000, width: 160, height: 100))
        })
    }
    private func settle(_ condition: () async -> Bool) async {
        for _ in 0..<1000 {
            if await condition() { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("condition did not settle")
    }
    func testZeroIsConfirmedImageWithoutAnyHardwareWriteAndDiscoveryKeepsZero() async {
        let provider = ZeroProvider(), blackout = controller(), osd = ZeroOSD()
        let model = DisplayBrightnessModel(provider: provider, osd: osd, blackout: blackout)
        defer { model.stop() }
        await model.refresh()
        model.request(id: "a", value: 0, fromKeys: true)
        await settle { model.pending.isEmpty }
        XCTAssertNotNil(blackout.panels["a"])
        XCTAssertEqual(model.displays.first?.value, 0)
        XCTAssertEqual(osd.shown, [0])
        let calls = await provider.calls; XCTAssertTrue(calls.isEmpty)
        await model.refresh()
        XCTAssertEqual(model.displays.first?.value, 0)
        XCTAssertNotNil(blackout.panels["a"])
    }
    func testPositiveRequestUncoversImmediatelyBeforeHeldOrFailedHardwareWrite() async {
        for fail in [false, true] {
            let provider = ZeroProvider(), blackout = controller()
            let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
            defer { model.stop() }
            await model.refresh(); await model.apply(id: "a", value: 0)
            XCTAssertNotNil(blackout.panels["a"])
            await provider.configure(hold: true, fail: fail)
            model.request(id: "a", value: 0.7)
            XCTAssertNil(blackout.panels["a"], "recovery cannot wait for hardware")
            XCTAssertEqual(model.displays.first?.value, 0.5, "show actual underlying value while awaiting hardware")
            await settle { await provider.calls.count == 1 }
            await provider.release(); await settle { model.pending.isEmpty }
            XCTAssertNil(blackout.panels["a"])
            XCTAssertEqual(model.displays.first?.value, fail ? 0.5 : 0.7)
            if fail { XCTAssertNotNil(model.errors["a"]) }
        }
    }
    func testKeyUpFromZeroUncoversAndKeepsExistingPositiveKeyStep() async {
        let provider = ZeroProvider(), blackout = controller()
        let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
        defer { model.stop() }
        await model.refresh(); await model.apply(id: "a", value: 0)
        model.handleKey(increase: true, fine: false, at: CGPoint(x: 50, y: 50))
        XCTAssertNil(blackout.panels["a"])
        await settle { model.pending.isEmpty }
        let calls = await provider.calls
        XCTAssertEqual(calls.map(\.1), [0.0625])
        XCTAssertEqual(model.displays.first?.value, 0.0625)
    }
    func testSupersededZeroAndCancellationCannotReblackDisplayAfterRecovery() async {
        let provider = ZeroProvider(), blackout = controller()
        let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
        await model.refresh(); await provider.configure(hold: true)
        model.request(id: "a", value: 0.7)
        await settle { await provider.calls.count == 1 }
        model.request(id: "a", value: 0)
        model.request(id: "a", value: 0.8)
        await provider.release(); await settle { model.pending.isEmpty }
        XCTAssertTrue(blackout.panels.isEmpty)
        let calls = await provider.calls; XCTAssertEqual(calls.map(\.1), [0.7, 0.8])
        await provider.configure(hold: true)
        model.request(id: "a", value: 0.6)
        await settle { await provider.calls.count == 3 }
        model.request(id: "a", value: 0)
        model.stop(); await provider.release()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertTrue(blackout.panels.isEmpty)
        let finalCalls = await provider.calls; XCTAssertEqual(finalCalls.count, 3)
    }
    func testSleepDisconnectMethodChangeAndStopRemoveBlackImage() async {
        for event in ["sleep", "disconnect", "method", "stop", "screens"] {
            let provider = ZeroProvider(), blackout = controller()
            let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
            var settings = DisplayBrightnessSettings()
            model.start { settings }; await model.refresh()
            await settle { !model.refreshing && !model.displays.isEmpty }
            await model.apply(id: "a", value: 0)
            XCTAssertNotNil(blackout.panels["a"])
            switch event {
            case "sleep": NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
            case "disconnect": await provider.disconnect(); await model.refresh()
            case "method": settings.methods["a"] = .software; await model.refresh()
            case "screens": NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
            default: model.stop()
            }
            await settle { blackout.panels.isEmpty }; model.stop()
        }
    }
    func testMissingOrMismatchedScreenCannotFallbackToHardwareZero() async {
        let provider = ZeroProvider()
        let blackout = BrightnessBlackoutController(target: { display in
            BrightnessBlackoutTarget(id: "different", displayID: display.displayID,
                frame: CGRect(x: -4000, y: -4000, width: 160, height: 100))
        })
        let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
        defer { model.stop() }
        await model.refresh(); await model.apply(id: "a", value: 0)
        let calls = await provider.calls; XCTAssertTrue(calls.isEmpty)
        XCTAssertTrue(blackout.panels.isEmpty); XCTAssertNotNil(model.errors["a"])
        XCTAssertEqual(model.displays.first?.value, 0.5)
    }
    func testNativeBlackPanelIsClickThroughAndBelowOSDAndRefreshChecksIdentity() throws {
        let blackout = controller()
        defer { blackout.clear() }
        let display = BrightnessDisplay(id: "a", displayID: 1, name: "fixture", bounds: .zero, builtIn: false, value: 0.5)
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        XCTAssertEqual(try blackout.cover(display), 0)
        let panel = try XCTUnwrap(blackout.panels["a"])
        XCTAssertTrue(panel.ignoresMouseEvents); XCTAssertFalse(panel.canBecomeKey); XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.isOpaque); XCTAssertEqual(panel.alphaValue, 1); XCTAssertEqual(panel.backgroundColor, .black)
        XCTAssertEqual(NSWorkspace.shared.frontmostApplication?.processIdentifier, front)
        let screen = try XCTUnwrap(NSScreen.screens.first)
        let osd = BrightnessOSDController(screen: { _ in screen }); defer { osd.hide() }
        osd.show(display: display, value: 0)
        XCTAssertGreaterThan(try XCTUnwrap(osd.panel).level.rawValue, panel.level.rawValue)
        var observed = display; observed.value = 0.6
        XCTAssertEqual(blackout.reconcile([observed]).first?.value, 0)
        XCTAssertEqual(blackout.uncover(id: "a"), 0.6)
        _ = try blackout.cover(display)
        let replaced = BrightnessDisplay(id: "a", displayID: 2, name: "reused", bounds: .zero, builtIn: false, value: 0.7)
        XCTAssertEqual(blackout.reconcile([replaced]).first?.value, 0.7)
        XCTAssertTrue(blackout.panels.isEmpty)
        let denied = BrightnessBlackoutController(target: { _ in nil })
        XCTAssertThrowsError(try denied.cover(display))
        let wrongID = BrightnessBlackoutController(target: { _ in BrightnessBlackoutTarget(id: "a", displayID: 2, frame: panel.frame) })
        XCTAssertThrowsError(try wrongID.cover(display))
    }
    func testCancellationBeforeOrAfterPanelCreationLeavesNoCover() {
        let display = BrightnessDisplay(id: "a", displayID: 1, name: "fixture", bounds: .zero, builtIn: false, value: 0.5)
        for cancelAt in [1, 2] {
            var checks = 0
            let blackout = BrightnessBlackoutController(target: { display in
                BrightnessBlackoutTarget(id: display.id, displayID: display.displayID,
                    frame: CGRect(x: -4000, y: -4000, width: 160, height: 100))
            }, cancelled: { checks += 1; return checks == cancelAt })
            XCTAssertThrowsError(try blackout.cover(display)) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertTrue(blackout.panels.isEmpty)
        }
    }
    func testLinkedZeroAndPositiveRecoveryPreserveKeySemanticsInBothMethods() async {
        for method: BrightnessMethod in [.hardware, .software] {
            let provider = ZeroProvider(), blackout = controller()
            let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
            var settings = DisplayBrightnessSettings(); settings.linkKeys = true; settings.methods["a"] = method
            model.start { settings }; await model.refresh()
            await settle { !model.refreshing && !model.displays.isEmpty }
            model.request(id: "a", value: 0, fromKeys: true)
            await settle { model.pending.isEmpty }
            XCTAssertEqual(Set(blackout.panels.keys), ["a", "b"])
            let initialCalls = await provider.calls; XCTAssertTrue(initialCalls.isEmpty)
            model.handleKey(increase: true, fine: false, at: CGPoint(x: 150, y: 50))
            XCTAssertTrue(blackout.panels.isEmpty)
            await settle { model.pending.isEmpty }
            let calls = await provider.calls
            XCTAssertEqual(Set(calls.map(\.0)), ["a", "b"])
            XCTAssertTrue(calls.allSatisfy { $0.1 == 0.0625 })
            model.stop()
        }
    }
    func testReleasingOwnerCannotLeaveAnOrphanBlackPanel() async throws {
        var blackout: BrightnessBlackoutController? = controller()
        let display = BrightnessDisplay(id: "a", displayID: 1, name: "fixture", bounds: .zero, builtIn: false, value: 0.5)
        _ = try blackout?.cover(display)
        let panel = try XCTUnwrap(blackout?.panels["a"])
        weak var owner = blackout
        blackout = nil
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(owner); XCTAssertFalse(panel.isVisible)
    }
}
