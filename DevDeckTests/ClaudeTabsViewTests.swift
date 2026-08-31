import XCTest
@testable import DevDeck

/// `SnapshotRowAction.isVisible` — the pure rule FIX 2 hangs the per-row "Open" action's
/// visibility on: never for a row with no resolved session, and never for one whose session is
/// already open right now, since pressing it there would only add a second tab for the same
/// session. Tested directly, as a pure function of (session id, open set), rather than through the
/// view.
final class ClaudeTabsViewTests: XCTestCase {
    func testHiddenWhenThereIsNoSessionAtAll() {
        XCTAssertFalse(SnapshotRowAction.isVisible(sessionID: nil, openSessionIDs: []),
                       "a directory-only row has nothing to reopen")
    }

    func testHiddenWhenTheSessionIsAlreadyOpen() {
        XCTAssertFalse(SnapshotRowAction.isVisible(sessionID: "s1", openSessionIDs: ["s1"]),
                       "pressing the action here would only open a second tab for the same session")
    }

    func testVisibleWhenTheSessionIsNotOpen() {
        XCTAssertTrue(SnapshotRowAction.isVisible(sessionID: "s1", openSessionIDs: []),
                      "after a reboot, before a restore, every snapshot row's session is not open "
                      + "yet — this is exactly the case the action must stay visible for")
    }

    func testVisibleWhenOtherSessionsAreOpenButNotThisOne() {
        XCTAssertTrue(SnapshotRowAction.isVisible(sessionID: "s1", openSessionIDs: ["s2", "s3"]))
    }
}
