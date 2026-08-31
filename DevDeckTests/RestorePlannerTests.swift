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
                        restored: Date? = nil, openTabs: Int = 1,
                        force: Bool = false) -> RestoreDecision {
        RestorePlanner.decide(snapshot: snap, enabled: enabled, currentBootTime: thisBoot,
                              restoredBootTime: restored, openTabCount: openTabs, force: force)
    }

    func testRestoresAfterReboot() {
        XCTAssertEqual(decide(snapshot(2)),
                       .restore([.inputText(cwd: "/tmp/0", sessionID: "s0", provider: "claude"),
                                 .newTab(cwd: "/tmp/1", sessionID: "s1", provider: "claude")]))
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
        XCTAssertEqual(actions, [.newTab(cwd: "/tmp/0", sessionID: "s0", provider: "claude"),
                                 .newTab(cwd: "/tmp/1", sessionID: "s1", provider: "claude")])
    }

    func testCapsTheNumberOfTabs() {
        guard case let .restore(actions) = decide(snapshot(50)) else { return XCTFail("expected restore") }
        XCTAssertEqual(actions.count, RestorePlanner.maxTabs)
    }

    // MARK: - Forced ("Restore now")

    /// The button used to be a no-op in every situation anyone would press it: the capture timer
    /// stamps a snapshot with the current boot within a minute of every launch, and the same-boot
    /// guard then swallowed the forced restore too.
    func testForcedRestoreIgnoresTheSameBootGuard() {
        guard case let .restore(actions) = decide(snapshot(2, boot: thisBoot), force: true) else {
            return XCTFail("expected restore")
        }
        XCTAssertEqual(actions.count, 2)
    }

    func testForcedRestoreIgnoresAlreadyRestoredInThisBoot() {
        guard case .restore = decide(snapshot(2), restored: thisBoot, force: true) else {
            return XCTFail("expected restore")
        }
    }

    func testForcedRestoreIgnoresTheFeatureFlag() {
        guard case .restore = decide(snapshot(2), enabled: false, force: true) else {
            return XCTFail("expected restore")
        }
    }

    /// Force cannot conjure tabs out of nothing: the two guards that describe reality stay.
    func testForcedRestoreStillSkipsWithoutASnapshot() {
        guard case .skip = decide(nil, force: true) else { return XCTFail("expected skip") }
    }

    func testForcedRestoreStillSkipsOnAnEmptySnapshot() {
        guard case .skip = decide(snapshot(0), force: true) else { return XCTFail("expected skip") }
    }

    // MARK: - Boot-time granularity

    /// `kern.boottime` is recomputed whenever the wall clock is set, and NTP corrects the clock a
    /// minute or two into every boot. Compared exactly, that microsecond drift would restore the
    /// tabs again on top of the ones already open, and again on every Ghostty launch after that.
    func testATinyDriftInTheBootTimeIsStillTheSameBoot() {
        let drifted = thisBoot.addingTimeInterval(0.004)
        guard case .skip = decide(snapshot(2, boot: drifted)) else { return XCTFail("expected skip") }
        guard case .skip = decide(snapshot(2), restored: drifted) else { return XCTFail("expected skip") }
    }

    /// And a real reboot is still a real reboot: boot times then sit minutes apart at the very
    /// least, so the tolerance never swallows one.
    func testAnActualRebootIsStillDetected() {
        guard case .restore = decide(snapshot(2, boot: thisBoot.addingTimeInterval(-3_600))) else {
            return XCTFail("expected restore")
        }
    }

    /// `openTabCount == 1` is strict on purpose. Zero is a real value — it is what the caller
    /// passes when Ghostty cannot be queried yet — and reusing "the first tab" when there is no
    /// tab means typing into something that may not exist.
    func testAllNewTabsWhenGhosttyReportsNoTabs() {
        guard case let .restore(actions) = decide(snapshot(2), openTabs: 0) else {
            return XCTFail("expected restore")
        }
        XCTAssertEqual(actions, [.newTab(cwd: "/tmp/0", sessionID: "s0", provider: "claude"),
                                 .newTab(cwd: "/tmp/1", sessionID: "s1", provider: "claude")])
    }

    // MARK: - Provider identity

    /// Every other test in this file builds a snapshot whose entries all share one provider, so a
    /// planner that hard-codes `"claude"` on every action instead of reading `entry.provider` would
    /// pass every one of them. A snapshot mixing providers is the only way to pin that each action
    /// carries the id of the entry it came from, not a constant.
    func testEachActionCarriesItsOwnEntrysProvider() {
        let mixed = ClaudeTabsSnapshot(
            bootTime: lastBoot, capturedAt: Date(timeIntervalSince1970: 1_500),
            tabs: [
                ClaudeTabEntry(order: 0, title: "oc", workingDirectory: "/tmp/oc",
                              sessionID: "ses_a", provider: "opencode"),
                ClaudeTabEntry(order: 1, title: "cc", workingDirectory: "/tmp/cc",
                              sessionID: "s1", provider: "claude"),
            ])
        guard case let .restore(actions) = decide(mixed, openTabs: 3) else {
            return XCTFail("expected restore")
        }
        XCTAssertEqual(actions, [.newTab(cwd: "/tmp/oc", sessionID: "ses_a", provider: "opencode"),
                                 .newTab(cwd: "/tmp/cc", sessionID: "s1", provider: "claude")])
    }
}
