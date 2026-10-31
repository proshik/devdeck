import XCTest
@testable import DevDeck

@MainActor private final class FakeClipboardPasting: ClipboardPasting {
    var trusted = true
    var target: ClipboardPasteTarget? = .init(identity: UUID(), pid: 12345, name: "Editor")
    var available = true
    var acceptsActivation = true
    var frontmost = true
    var events: [String] = []
    func start() {}
    func stop() {}
    func captureTarget() {}
    func requestPermission() { events.append("permission") }
    func isAvailable(_ target: ClipboardPasteTarget) -> Bool { available && self.target == target }
    func activate(_ target: ClipboardPasteTarget) -> Bool { events.append("activate"); return acceptsActivation }
    func isFrontmost(_ target: ClipboardPasteTarget) -> Bool { frontmost }
    func sendPaste(to target: ClipboardPasteTarget) -> Bool { events.append("paste"); return true }
}

@MainActor final class ClipboardPasteTests: XCTestCase {
    func testPasteRestoresCapturedTargetAfterCopyAndDismiss() async {
        let platform = FakeClipboardPasting()
        let controller = ClipboardPasteController(platform: platform, pause: {})
        let result = await controller.perform(enabled: true, changeCount: { 7 }, copy: { platform.events.append("copy"); return 7 }, dismiss: { platform.events.append("dismiss") })
        XCTAssertNil(result)
        XCTAssertEqual(platform.events, ["copy", "dismiss", "activate", "paste"])
    }
    func testPermissionDisabledMissingAndClosedTargetNeverCopyOrPaste() async {
        for scenario in 0..<4 {
            let platform = FakeClipboardPasting()
            if scenario == 1 { platform.trusted = false }
            if scenario == 2 { platform.target = nil }
            if scenario == 3 { platform.available = false }
            let controller = ClipboardPasteController(platform: platform, pause: {})
            let result = await controller.perform(enabled: scenario != 0, changeCount: { 7 }, copy: { platform.events.append("copy"); return 7 }, dismiss: { platform.events.append("dismiss") })
            XCTAssertEqual(result, scenario == 0 ? .disabled : scenario == 1 ? .permission : .target)
            XCTAssertTrue(platform.events.isEmpty)
        }
    }
    func testFailedCopyActivationOrFocusNeverSendsPaste() async {
        for scenario in 0..<3 {
            let platform = FakeClipboardPasting()
            platform.acceptsActivation = scenario != 1; platform.frontmost = scenario != 2
            let controller = ClipboardPasteController(platform: platform, pause: {})
            let result = await controller.perform(enabled: true, changeCount: { 7 }, copy: { scenario == 0 ? nil : 7 }, dismiss: {})
            XCTAssertEqual(result, scenario == 0 ? .copy : .target)
            XCTAssertFalse(platform.events.contains("paste"))
        }
    }
    func testChangedClipboardOrTargetDuringActivationCancelsPaste() async {
        for changeTarget in [false, true] {
            let platform = FakeClipboardPasting(); platform.frontmost = false
            var count = 7
            let controller = ClipboardPasteController(platform: platform, pause: {
                platform.frontmost = true
                if changeTarget { platform.target = .init(identity: UUID(), pid: 12345, name: "New process") }
                else { count = 8 }
            })
            let result = await controller.perform(enabled: true, changeCount: { count }, copy: { 7 }, dismiss: {})
            XCTAssertEqual(result, changeTarget ? .target : .changed)
            XCTAssertFalse(platform.events.contains("paste"))
        }
    }
    func testOverlappingAndCancelledPasteCannotSendExtraEvents() async {
        let platform = FakeClipboardPasting(); platform.frontmost = false
        var overlap: ClipboardPasteFailure?
        var controller: ClipboardPasteController!
        controller = ClipboardPasteController(platform: platform, pause: {
            overlap = await controller.perform(enabled: true, changeCount: { 7 }, copy: { 7 }, dismiss: {})
            platform.frontmost = true
        })
        let result = await controller.perform(enabled: true, changeCount: { 7 }, copy: { 7 }, dismiss: {})
        XCTAssertNil(result); XCTAssertEqual(overlap, .busy)
        XCTAssertEqual(platform.events.filter { $0 == "paste" }.count, 1)
        platform.events = []
        let task = Task { await controller.perform(enabled: true, changeCount: { 7 }, copy: { 7 }, dismiss: {}) }
        task.cancel()
        let cancelled = await task.value
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertTrue(platform.events.isEmpty)
    }
}
