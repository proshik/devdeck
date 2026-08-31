import XCTest
@testable import DevDeck

/// `ClaudeSessionProvider` — Claude Code behind the `AgentSessionProvider` protocol. Its
/// `sessions`/`normalize` logic is the same as before the protocol existed; these tests pin that
/// nothing changed in the move.
final class ClaudeSessionProviderTests: XCTestCase {

    /// Records what it was called with, so a test can prove `ClaudeSessionProvider` forwards
    /// `since`/`known` to its index rather than swallowing either. `@unchecked Sendable` — test-only,
    /// single-threaded, same allowance `OpencodeSessionProviderTests.CountingFetch` takes.
    private final class FakeTranscriptIndex: TranscriptIndexing, @unchecked Sendable {
        var byDirectory: [String: [TranscriptTitle]] = [:]
        var recent: [RecentTranscript] = []
        private(set) var lastSince: Date?
        private(set) var lastKnown: [String: KnownTranscript]?

        init(byDirectory: [String: [TranscriptTitle]] = [:], recent: [RecentTranscript] = []) {
            self.byDirectory = byDirectory
            self.recent = recent
        }

        func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle] {
            byDirectory[workingDirectory] ?? []
        }

        func recentTranscripts(since: Date, known: [String: KnownTranscript]) -> [RecentTranscript] {
            lastSince = since
            lastKnown = known
            return recent
        }
    }

    private func provider(index: TranscriptIndexing = FakeTranscriptIndex(),
                          backgroundIDs: Set<String> = [],
                          knownTranscripts: [String: KnownTranscript] = [:]) -> ClaudeSessionProvider {
        ClaudeSessionProvider(index: index, backgroundSessions: FakeBackgroundSessions(ids: backgroundIDs),
                             knownTranscripts: knownTranscripts)
    }

    func testIDIsClaude() {
        XCTAssertEqual(provider().id, "claude")
        XCTAssertEqual(provider().id, AgentProviderID.claude)
    }

    /// Claude has no prefix of its own — it must claim every tab title handed to it, glyph or not.
    func testMayOwnIsAlwaysTrue() {
        let claude = provider()
        XCTAssertTrue(claude.mayOwn(tabTitle: "✳ fix-own-memory"))
        XCTAssertTrue(claude.mayOwn(tabTitle: "zsh"))
        XCTAssertTrue(claude.mayOwn(tabTitle: ""))
        XCTAssertTrue(claude.mayOwn(tabTitle: "OC | some opencode session"))
    }

    func testStripsStatusGlyph() {
        let claude = provider()
        XCTAssertEqual(claude.normalize(tabTitle: "✳ fix-own-memory"), "fix-own-memory")
        XCTAssertEqual(claude.normalize(tabTitle: "◐  Ghostty session"), "Ghostty session")
    }

    func testNormalizeReturnsEmptyForAGlyphOnlyTitle() {
        let claude = provider()
        XCTAssertEqual(claude.normalize(tabTitle: "✳"), "")
        XCTAssertEqual(claude.normalize(tabTitle: "  ◐  "), "")
    }

    /// `sessions(inDirectory:)` is a thin map from `TranscriptTitle` to `AgentSession` — id, title
    /// and mtime carried straight across, newest first exactly as `LiveTranscriptIndex` promises.
    func testSessionsMapsTranscriptTitlesToAgentSessions() {
        let claude = provider(index: FakeTranscriptIndex(byDirectory: [
            "/tmp/a": [TranscriptTitle(aiTitle: "alpha", sessionID: "s1",
                                       modifiedAt: Date(timeIntervalSince1970: 20)),
                       TranscriptTitle(aiTitle: "beta", sessionID: "s2",
                                       modifiedAt: Date(timeIntervalSince1970: 10))]
        ]))
        let sessions = claude.sessions(inDirectory: "/tmp/a")
        XCTAssertEqual(sessions, [
            AgentSession(id: "s1", title: "alpha", lastActivity: Date(timeIntervalSince1970: 20), directory: "/tmp/a"),
            AgentSession(id: "s2", title: "beta", lastActivity: Date(timeIntervalSince1970: 10), directory: "/tmp/a"),
        ])
    }

    func testSessionsIsEmptyForAnUnknownDirectory() {
        XCTAssertTrue(provider().sessions(inDirectory: "/tmp/nope").isEmpty)
    }

    // MARK: - recentSessions(since:)

    /// A thin map from `RecentTranscript` to `AgentSession`, mirroring `sessions(inDirectory:)` —
    /// the actual window/skip/reuse behaviour is `LiveTranscriptIndex`'s, pinned in
    /// `TranscriptIndexTests`; this only pins that `ClaudeSessionProvider` carries the fields
    /// across correctly.
    func testRecentSessionsMapsRecentTranscriptsToAgentSessions() {
        let index = FakeTranscriptIndex(recent: [
            RecentTranscript(title: TranscriptTitle(aiTitle: "alpha", sessionID: "s1",
                                                    modifiedAt: Date(timeIntervalSince1970: 20)),
                             directory: "/tmp/a", sourcePath: "/tmp/a.jsonl"),
        ])
        let sessions = provider(index: index).recentSessions(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(sessions, [
            AgentSession(id: "s1", title: "alpha", lastActivity: Date(timeIntervalSince1970: 20), directory: "/tmp/a"),
        ])
    }

    /// `since` and the provider's own `knownTranscripts` must reach the index unchanged — this is
    /// the whole of what lets a catalog rebuild skip re-reading a transcript across an app restart.
    func testRecentSessionsForwardsSinceAndKnownTranscriptsToTheIndex() {
        let index = FakeTranscriptIndex()
        let known = ["/tmp/a.jsonl": KnownTranscript(
            modifiedAt: Date(timeIntervalSince1970: 5),
            title: TranscriptTitle(aiTitle: "alpha", sessionID: "s1", modifiedAt: Date(timeIntervalSince1970: 5)),
            directory: "/tmp/a")]
        let since = Date(timeIntervalSince1970: 100)
        _ = provider(index: index, knownTranscripts: known).recentSessions(since: since)
        XCTAssertEqual(index.lastSince, since)
        XCTAssertEqual(index.lastKnown, known)
    }

    // MARK: - command(resuming:in:)

    func testCommandResumesAnOrdinarySession() {
        XCTAssertEqual(provider().command(resuming: "s1", in: "/tmp/a"),
                       "cd '/tmp/a' && claude --resume 's1'")
    }

    /// A session currently running in the background must attach instead — `--resume` refuses
    /// those outright. This is the property `TabRestorer` relies on when Task 2 moves the call
    /// site here.
    func testCommandAttachesToABackgroundSession() {
        XCTAssertEqual(provider(backgroundIDs: ["bg"]).command(resuming: "bg", in: "/tmp/a"),
                       "cd '/tmp/a' && claude attach 'bg'")
    }

    func testCommandQuotesAnAwkwardWorkingDirectory() {
        XCTAssertEqual(provider().command(resuming: "s1", in: "/tmp/it's here"),
                       #"cd '/tmp/it'\''s here' && claude --resume 's1'"#)
    }
}
