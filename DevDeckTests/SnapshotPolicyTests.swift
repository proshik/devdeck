import XCTest
@testable import DevDeck

/// The one rule that keeps the feature from destroying itself: quitting Ghostty normally leaves
/// zero tabs, and writing that empty result would wipe the snapshot right before the shutdown
/// the whole feature exists for.
final class SnapshotPolicyTests: XCTestCase {

    func testEmptyResultIsNotPersisted() {
        XCTAssertFalse(SnapshotPolicy.shouldPersist([]))
    }

    func testNonEmptyResultIsPersisted() {
        let entries = [ClaudeTabEntry(order: 0, title: "t", workingDirectory: "/tmp", sessionID: "s")]
        XCTAssertTrue(SnapshotPolicy.shouldPersist(entries))
    }
}
