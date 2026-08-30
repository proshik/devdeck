import XCTest
@testable import DevDeck

/// The one rule that keeps the feature from destroying itself. The spec states it as "at least one
/// tab was RESOLVED", and that stronger form matters twice: quitting Ghostty normally leaves zero
/// tabs, and the moment right after a restore leaves tabs whose titles are still the shell's. Both
/// would otherwise overwrite a good snapshot with one that restores nothing.
final class SnapshotPolicyTests: XCTestCase {

    private func entry(_ sessionID: String?) -> ClaudeTabEntry {
        ClaudeTabEntry(order: 0, title: "t", workingDirectory: "/tmp", sessionID: sessionID)
    }

    func testEmptyResultIsNotPersisted() {
        XCTAssertFalse(SnapshotPolicy.shouldPersist([]))
    }

    /// The case the old `!entries.isEmpty` rule could never see: tabs are open, none of them
    /// resolved. Writing this replaces a restorable snapshot with a list of bare directories.
    func testEntriesWithoutAnySessionAreNotPersisted() {
        XCTAssertFalse(SnapshotPolicy.shouldPersist([entry(nil), entry(nil)]))
    }

    /// One resolved tab is enough — the unresolved ones travel with it and restore as shells in
    /// their directories, which is the degradation ladder working as designed.
    func testOneResolvedTabIsEnough() {
        XCTAssertTrue(SnapshotPolicy.shouldPersist([entry(nil), entry("s1")]))
    }

    func testAllResolvedIsPersisted() {
        XCTAssertTrue(SnapshotPolicy.shouldPersist([entry("s1")]))
    }
}
