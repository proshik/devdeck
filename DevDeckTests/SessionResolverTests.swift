import XCTest
@testable import DevDeck

/// Matching a Ghostty tab to an agent session. Pure — no Ghostty, no filesystem, no live provider.
final class SessionResolverTests: XCTestCase {

    private struct FakeTranscriptIndex: TranscriptIndexing {
        var byDirectory: [String: [TranscriptTitle]] = [:]
        func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle] {
            byDirectory[workingDirectory] ?? []
        }
        func recentTranscripts(since: Date, known: [String: KnownTranscript]) -> [RecentTranscript] { [] }
    }

    private func title(_ text: String, _ id: String, _ seconds: TimeInterval) -> TranscriptTitle {
        TranscriptTitle(aiTitle: text, sessionID: id, modifiedAt: Date(timeIntervalSince1970: seconds))
    }

    private func tab(_ index: Int, _ title: String, _ cwd: String) -> GhosttyTab {
        GhosttyTab(windowID: "w1", index: index, title: title, workingDirectory: cwd)
    }

    /// A single-provider setup — Claude, wired to a fake transcript index — for the tests that are
    /// about the matching mechanics rather than the multi-provider dispatch itself.
    private func claude(_ byDirectory: [String: [TranscriptTitle]]) -> [AgentSessionProvider] {
        [ClaudeSessionProvider(index: FakeTranscriptIndex(byDirectory: byDirectory),
                               backgroundSessions: FakeBackgroundSessions(ids: []))]
    }

    func testExactMatch() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "✳ alpha", "/tmp/a")],
            providers: claude(["/tmp/a": [title("alpha", "s1", 10)]]))
        XCTAssertEqual(entries.map(\.sessionID), ["s1"])
        XCTAssertEqual(entries.map(\.provider), ["claude"])
    }

    func testPrefixMatchForTruncatedTitle() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "✳ long title that got", "/tmp/a")],
            providers: claude(["/tmp/a": [title("long title that got cut off", "s1", 10)]]))
        XCTAssertEqual(entries.map(\.sessionID), ["s1"])
    }

    func testTwoTabsWithTheSameTitleGetDifferentSessions() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "✳ same", "/tmp/a"), tab(2, "✳ same", "/tmp/a")],
            providers: claude(["/tmp/a": [title("same", "newer", 20), title("same", "older", 10)]]))
        XCTAssertEqual(entries.map(\.sessionID), ["newer", "older"])
    }

    func testUnresolvedTabIsKeptWithoutSession() {
        let entries = SessionResolver.resolve(tabs: [tab(1, "zsh", "/tmp/a")], providers: claude([:]))
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].sessionID)
        XCTAssertEqual(entries[0].workingDirectory, "/tmp/a")
        XCTAssertEqual(entries[0].provider, "claude", "an unresolved tab still defaults to claude")
    }

    func testOrderFollowsWindowThenTabIndex() {
        let tabs = [GhosttyTab(windowID: "w2", index: 1, title: "c", workingDirectory: "/tmp/c"),
                    GhosttyTab(windowID: "w1", index: 2, title: "b", workingDirectory: "/tmp/b"),
                    GhosttyTab(windowID: "w1", index: 1, title: "a", workingDirectory: "/tmp/a")]
        let entries = SessionResolver.resolve(tabs: tabs, providers: [])
        XCTAssertEqual(entries.map(\.order), [0, 1, 2])
        XCTAssertEqual(entries.map(\.workingDirectory), ["/tmp/a", "/tmp/b", "/tmp/c"])
    }

    /// The prefix stage must not fire on an empty needle: `anything.hasPrefix("")` is true, so an
    /// unguarded prefix match would bind a glyph-only tab title to the first session in its directory.
    func testGlyphOnlyTitleMatchesNothingEvenWithCandidatesPresent() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "✳", "/tmp/a")],
            providers: claude(["/tmp/a": [title("alpha", "s1", 10)]]))
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].sessionID)
    }

    // MARK: - Multi-provider dispatch

    /// A minimal fake, independent of `ClaudeSessionProvider`, so the resolver's own dispatch logic
    /// — provider order, `mayOwn` filtering, per-provider claiming — is tested in isolation.
    private struct FakeProvider: AgentSessionProvider {
        var id: String
        var isFallback = false
        var owns: (String) -> Bool = { _ in true }
        var byDirectory: [String: [AgentSession]] = [:]

        func mayOwn(tabTitle: String) -> Bool { owns(tabTitle) }
        func sessions(inDirectory directory: String) -> [AgentSession] { byDirectory[directory] ?? [] }
        func recentSessions(since: Date) -> [AgentSession] { [] }
        func normalize(tabTitle: String) -> String { tabTitle }
        func command(resuming sessionID: String, in cwd: String) -> String { "" }
    }

    /// A tab whose title only the second provider recognizes must skip straight past the first,
    /// not settle for a coincidental match there.
    func testATabTheFirstProviderDoesNotOwnFallsThroughToTheNext() {
        let first = FakeProvider(id: "first", owns: { _ in false })
        let second = FakeProvider(id: "second", byDirectory: ["/tmp/a": [AgentSession(
            id: "s1", title: "alpha", lastActivity: Date())]])
        let entries = SessionResolver.resolve(tabs: [tab(1, "alpha", "/tmp/a")], providers: [first, second])
        XCTAssertEqual(entries.map(\.sessionID), ["s1"])
        XCTAssertEqual(entries.map(\.provider), ["second"])
    }

    /// Two providers are both eligible and both have a session titled "alpha" — the first one in
    /// the list must win, exactly like the first candidate wins within one provider.
    func testFirstEligibleProviderWinsOverALaterOneThatAlsoMatches() {
        let first = FakeProvider(id: "first", byDirectory: ["/tmp/a": [AgentSession(
            id: "s1", title: "alpha", lastActivity: Date())]])
        let second = FakeProvider(id: "second", byDirectory: ["/tmp/a": [AgentSession(
            id: "s1", title: "alpha", lastActivity: Date())]])
        let entries = SessionResolver.resolve(tabs: [tab(1, "alpha", "/tmp/a")], providers: [first, second])
        XCTAssertEqual(entries.map(\.provider), ["first"])
    }

    /// The claim key is namespaced by provider: two providers handing out the identical raw
    /// session id "s1" must not make one's claim block the other's tab from resolving.
    func testTheSameRawSessionIDFromTwoDifferentProvidersDoesNotCollide() {
        let first = FakeProvider(id: "first", owns: { $0 == "one" }, byDirectory: [
            "/tmp/a": [AgentSession(id: "s1", title: "one", lastActivity: Date())]])
        let second = FakeProvider(id: "second", owns: { $0 == "two" }, byDirectory: [
            "/tmp/a": [AgentSession(id: "s1", title: "two", lastActivity: Date())]])
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "one", "/tmp/a"), tab(2, "two", "/tmp/a")],
            providers: [first, second])
        XCTAssertEqual(entries.map(\.sessionID), ["s1", "s1"],
                       "the same raw id from two different providers must not be treated as one claim")
        XCTAssertEqual(entries.map(\.provider), ["first", "second"])
    }

    /// An unresolved tab must still name the agent it actually belongs to — the last non-fallback
    /// provider whose `mayOwn` claimed it — rather than defaulting to Claude just because Claude's
    /// unconditional `mayOwn` also happens to be tried and also finds nothing.
    func testUnresolvedTabRecordsTheLastProviderThatClaimedItNotTheFallback() {
        let owner = FakeProvider(id: "owner")
        let claude = FakeProvider(id: "claude", isFallback: true)
        let entries = SessionResolver.resolve(tabs: [tab(1, "alpha", "/tmp/a")], providers: [owner, claude])
        XCTAssertNil(entries[0].sessionID)
        XCTAssertEqual(entries[0].provider, "owner",
                       "the non-fallback provider that claimed the tab must be recorded, not the fallback")
    }

    // MARK: - isFallback ordering

    /// The rule "Claude is the fallback and must come last" used to live only in a comment,
    /// enforced nowhere: a caller who builds `[claude, opencode]` used to get claude's
    /// unconditional `mayOwn` swallowing the tab before opencode ever saw it. `isFallback` fixes
    /// that in the resolver itself, so the caller's array order stops mattering.
    ///
    /// `claude` here would win the match too if tried first — its own candidate title is set to
    /// look exactly like the tab wants — so this only passes if `resolve` truly tries the
    /// non-fallback provider first, not because claude had nothing to offer.
    func testFallbackProviderIsTriedLastEvenWhenListedFirstInTheArray() {
        let claude = FakeProvider(id: "claude", isFallback: true, byDirectory: [
            "/tmp/a": [AgentSession(id: "wrong-provider-would-win", title: "OC | alpha", lastActivity: Date())]])
        let opencode = FakeProvider(id: "opencode", owns: { $0.hasPrefix("OC | ") }, byDirectory: [
            "/tmp/a": [AgentSession(id: "s1", title: "OC | alpha", lastActivity: Date())]])

        let entries = SessionResolver.resolve(tabs: [tab(1, "OC | alpha", "/tmp/a")],
                                              providers: [claude, opencode])

        XCTAssertEqual(entries.map(\.provider), ["opencode"],
                       "a caller-supplied [claude, opencode] order must not let claude win the tab")
        XCTAssertEqual(entries.map(\.sessionID), ["s1"])
    }

    /// Two non-fallback providers must keep the order the caller gave them — `isFallback` only
    /// ever demotes the fallback, it must not otherwise reshuffle the array.
    func testTwoNonFallbackProvidersKeepTheirGivenOrder() {
        let first = FakeProvider(id: "first", byDirectory: ["/tmp/a": [AgentSession(
            id: "s1", title: "alpha", lastActivity: Date())]])
        let second = FakeProvider(id: "second", byDirectory: ["/tmp/a": [AgentSession(
            id: "s1", title: "alpha", lastActivity: Date())]])

        let entries = SessionResolver.resolve(tabs: [tab(1, "alpha", "/tmp/a")], providers: [first, second])

        XCTAssertEqual(entries.map(\.provider), ["first"], "the caller's order must still decide between two eligible non-fallback providers")
    }
}
