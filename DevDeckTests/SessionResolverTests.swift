import XCTest
@testable import DevDeck

/// Matching a Ghostty tab to the Claude session running in it. Pure — no Ghostty, no filesystem.
final class SessionResolverTests: XCTestCase {

    private func title(_ text: String, _ id: String, _ seconds: TimeInterval) -> TranscriptTitle {
        TranscriptTitle(aiTitle: text, sessionID: id, modifiedAt: Date(timeIntervalSince1970: seconds))
    }

    private func tab(_ index: Int, _ title: String, _ cwd: String) -> GhosttyTab {
        GhosttyTab(windowID: "w1", index: index, title: title, workingDirectory: cwd)
    }

    func testStripsStatusGlyph() {
        XCTAssertEqual(SessionResolver.normalize("✳ fix-own-memory"), "fix-own-memory")
        XCTAssertEqual(SessionResolver.normalize("◐  Ghostty session"), "Ghostty session")
    }

    func testExactMatch() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "✳ alpha", "/tmp/a")],
            titlesByDirectory: ["/tmp/a": [title("alpha", "s1", 10)]])
        XCTAssertEqual(entries.map(\.sessionID), ["s1"])
    }

    func testPrefixMatchForTruncatedTitle() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "✳ long title that got", "/tmp/a")],
            titlesByDirectory: ["/tmp/a": [title("long title that got cut off", "s1", 10)]])
        XCTAssertEqual(entries.map(\.sessionID), ["s1"])
    }

    func testTwoTabsWithTheSameTitleGetDifferentSessions() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "✳ same", "/tmp/a"), tab(2, "✳ same", "/tmp/a")],
            titlesByDirectory: ["/tmp/a": [title("same", "newer", 20), title("same", "older", 10)]])
        XCTAssertEqual(entries.map(\.sessionID), ["newer", "older"])
    }

    func testUnresolvedTabIsKeptWithoutSession() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "zsh", "/tmp/a")],
            titlesByDirectory: [:])
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].sessionID)
        XCTAssertEqual(entries[0].workingDirectory, "/tmp/a")
    }

    func testOrderFollowsWindowThenTabIndex() {
        let tabs = [GhosttyTab(windowID: "w2", index: 1, title: "c", workingDirectory: "/tmp/c"),
                    GhosttyTab(windowID: "w1", index: 2, title: "b", workingDirectory: "/tmp/b"),
                    GhosttyTab(windowID: "w1", index: 1, title: "a", workingDirectory: "/tmp/a")]
        let entries = SessionResolver.resolve(tabs: tabs, titlesByDirectory: [:])
        XCTAssertEqual(entries.map(\.order), [0, 1, 2])
        XCTAssertEqual(entries.map(\.workingDirectory), ["/tmp/a", "/tmp/b", "/tmp/c"])
    }
}
