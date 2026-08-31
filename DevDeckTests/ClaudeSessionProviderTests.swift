import XCTest
@testable import DevDeck

/// `ClaudeSessionProvider` — Claude Code behind the `AgentSessionProvider` protocol. Its
/// `sessions`/`normalize` logic is the same as before the protocol existed; these tests pin that
/// nothing changed in the move.
final class ClaudeSessionProviderTests: XCTestCase {

    private struct FakeTranscriptIndex: TranscriptIndexing {
        var byDirectory: [String: [TranscriptTitle]] = [:]
        func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle] {
            byDirectory[workingDirectory] ?? []
        }
    }

    private func provider(index: TranscriptIndexing = FakeTranscriptIndex(),
                          backgroundIDs: Set<String> = []) -> ClaudeSessionProvider {
        ClaudeSessionProvider(index: index, backgroundSessions: FakeBackgroundSessions(ids: backgroundIDs))
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
            AgentSession(id: "s1", title: "alpha", lastActivity: Date(timeIntervalSince1970: 20)),
            AgentSession(id: "s2", title: "beta", lastActivity: Date(timeIntervalSince1970: 10)),
        ])
    }

    func testSessionsIsEmptyForAnUnknownDirectory() {
        XCTAssertTrue(provider().sessions(inDirectory: "/tmp/nope").isEmpty)
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
