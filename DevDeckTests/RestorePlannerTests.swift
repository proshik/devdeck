import XCTest
@testable import DevDeck

/// Deciding whether this Ghostty launch is the one that should restore tabs — and what to do.
/// Every branch here is a way to annoy the user (duplicate tabs, typing into someone else's
/// shell, a wall of processes), so all of them are pinned down.
final class RestorePlannerTests: XCTestCase {

    private let lastBoot = Date(timeIntervalSince1970: 1_000)
    private let thisBoot = Date(timeIntervalSince1970: 2_000)

    private func snapshot(_ count: Int, boot: Date? = nil) -> ClaudeTabsSnapshot {
        ClaudeTabsSnapshot(
            bootTime: boot ?? lastBoot,
            capturedAt: Date(timeIntervalSince1970: 1_500),
            tabs: (0..<count).map {
                ClaudeTabEntry(order: $0, title: "t\($0)", workingDirectory: "/tmp/\($0)", sessionID: "s\($0)")
            })
    }

    private func decide(_ snap: ClaudeTabsSnapshot?, enabled: Bool = true,
                        restored: Date? = nil, openTabs: Int = 1) -> RestoreDecision {
        RestorePlanner.decide(snapshot: snap, enabled: enabled, currentBootTime: thisBoot,
                              restoredBootTime: restored, openTabCount: openTabs)
    }

    func testRestoresAfterReboot() {
        XCTAssertEqual(decide(snapshot(2)),
                       .restore([.inputText(cwd: "/tmp/0", sessionID: "s0"),
                                 .newTab(cwd: "/tmp/1", sessionID: "s1")]))
    }

    func testSkipsWhenDisabled() {
        guard case .skip = decide(snapshot(2), enabled: false) else { return XCTFail("expected skip") }
    }

    func testSkipsWithoutSnapshot() {
        guard case .skip = decide(nil) else { return XCTFail("expected skip") }
    }

    func testSkipsOnEmptySnapshot() {
        guard case .skip = decide(snapshot(0)) else { return XCTFail("expected skip") }
    }

    func testSkipsWhenGhosttyMerelyRestartedInTheSameBoot() {
        guard case .skip = decide(snapshot(2, boot: thisBoot)) else { return XCTFail("expected skip") }
    }

    func testSkipsWhenAlreadyRestoredInThisBoot() {
        guard case .skip = decide(snapshot(2), restored: thisBoot) else { return XCTFail("expected skip") }
    }

    func testAllNewTabsWhenGhosttyAlreadyHasSeveralTabs() {
        guard case let .restore(actions) = decide(snapshot(2), openTabs: 3) else {
            return XCTFail("expected restore")
        }
        XCTAssertEqual(actions, [.newTab(cwd: "/tmp/0", sessionID: "s0"),
                                 .newTab(cwd: "/tmp/1", sessionID: "s1")])
    }

    func testCapsTheNumberOfTabs() {
        guard case let .restore(actions) = decide(snapshot(50)) else { return XCTFail("expected restore") }
        XCTAssertEqual(actions.count, RestorePlanner.maxTabs)
    }

    /// `openTabCount == 1` is strict on purpose. Zero is a real value — it is what the caller
    /// passes when Ghostty cannot be queried yet — and reusing "the first tab" when there is no
    /// tab means typing into something that may not exist.
    func testAllNewTabsWhenGhosttyReportsNoTabs() {
        guard case let .restore(actions) = decide(snapshot(2), openTabs: 0) else {
            return XCTFail("expected restore")
        }
        XCTAssertEqual(actions, [.newTab(cwd: "/tmp/0", sessionID: "s0"),
                                 .newTab(cwd: "/tmp/1", sessionID: "s1")])
    }
}
