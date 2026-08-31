import XCTest
@testable import DevDeck

/// A background session refuses `claude --resume` and must be opened with `claude attach`.
/// The listing comes from another tool's JSON, so parsing is lenient by design: anything we cannot
/// read must degrade to "not a background session", which restores with `--resume` — the right
/// answer whenever we cannot tell, and the only correct one after a reboot, when none are running.
final class BackgroundSessionsTests: XCTestCase {

    private func json(_ raw: String) -> Data { Data(raw.utf8) }

    func testPicksOnlyBackgroundKinds() {
        let data = json("""
        [{"sessionId":"aaa","kind":"interactive"},
         {"sessionId":"bbb","kind":"background","id":"bbb1234"},
         {"sessionId":"ccc","kind":"background"}]
        """)
        XCTAssertEqual(BackgroundSessions.parse(data), ["bbb", "ccc"])
    }

    func testEntryWithoutKindIsNotBackground() {
        XCTAssertEqual(BackgroundSessions.parse(json(#"[{"sessionId":"aaa"}]"#)), [])
    }

    func testMalformedOutputYieldsNothing() {
        XCTAssertEqual(BackgroundSessions.parse(json("not json at all")), [])
        XCTAssertEqual(BackgroundSessions.parse(json("{}")), [])
        XCTAssertEqual(BackgroundSessions.parse(Data()), [])
    }

    func testCommandAttachesToABackgroundSession() {
        XCTAssertEqual(RestoreCommand.text(cwd: "/tmp/a", sessionID: "s1", isBackground: true),
                       "cd '/tmp/a' && claude attach 's1'")
    }

    func testCommandResumesAnOrdinarySession() {
        XCTAssertEqual(RestoreCommand.text(cwd: "/tmp/a", sessionID: "s1", isBackground: false),
                       "cd '/tmp/a' && claude --resume 's1'")
    }

    func testRestorerAttachesOnlyTheBackgroundOnes() async {
        let runner = TabRestorerTests.FakeAppleScriptRunner()
        let restorer = TabRestorer(runner: runner,
                                   providers: [ClaudeSessionProvider(backgroundSessions: FakeBackgroundSessions(ids: ["bg"]))],
                                   stepDelay: .zero)
        _ = await restorer.restore([.newTab(cwd: "/tmp/a", sessionID: "bg", provider: "claude"),
                                    .newTab(cwd: "/tmp/b", sessionID: "plain", provider: "claude")])
        let scripts = runner.calls.map { $0.joined(separator: " ") }
        XCTAssertTrue(scripts[0].contains("claude attach 'bg'"), "a background session must attach")
        XCTAssertTrue(scripts[1].contains("claude --resume 'plain'"), "an ordinary session must resume")
    }

    /// The whole point of `prepareForRestore()`: a restore with several Claude entries must spawn
    /// `claude agents --json` exactly once, not once per entry. Without `prepareForRestore()`
    /// wired up (i.e. `command(resuming:in:)` asking the listing directly, as it used to) this
    /// count would be 3 — that difference is what this test pins, not just "it still works".
    func testRestoreAsksTheBackgroundListingOnlyOnceNoMatterHowManyEntriesResolveToClaude() async {
        let runner = TabRestorerTests.FakeAppleScriptRunner()
        let listing = CountingBackgroundSessions(ids: ["bg"])
        let restorer = TabRestorer(runner: runner,
                                   providers: [ClaudeSessionProvider(backgroundSessions: listing)],
                                   stepDelay: .zero)

        _ = await restorer.restore([.newTab(cwd: "/tmp/a", sessionID: "bg", provider: "claude"),
                                    .newTab(cwd: "/tmp/b", sessionID: "s2", provider: "claude"),
                                    .newTab(cwd: "/tmp/c", sessionID: "s3", provider: "claude")])

        XCTAssertEqual(listing.calls, 1,
                       "three Claude entries must share one background-session fetch for the whole restore")
        let scripts = runner.calls.map { $0.joined(separator: " ") }
        XCTAssertTrue(scripts[0].contains("claude attach 'bg'"),
                      "the cached fetch must still tell a background session from an ordinary one")
        XCTAssertTrue(scripts[1].contains("claude --resume 's2'"))
    }
}

/// No process is ever spawned in tests — the live listing shells out to `claude agents --json`.
struct FakeBackgroundSessions: BackgroundSessionListing {
    let ids: Set<String>
    func backgroundSessionIDs() -> Set<String> { ids }
}

/// Counts calls rather than just answering them — the fixture `testRestoreAsksTheBackgroundListingOnlyOnceNoMatterHowManyEntriesResolveToClaude`
/// needs to see, not just trust, that `prepareForRestore()` collapses N entries into one fetch.
final class CountingBackgroundSessions: BackgroundSessionListing, @unchecked Sendable {
    private let lock = NSLock()
    private let ids: Set<String>
    private var _calls = 0
    var calls: Int {
        lock.lock()
        defer { lock.unlock() }
        return _calls
    }

    init(ids: Set<String>) { self.ids = ids }

    func backgroundSessionIDs() -> Set<String> {
        lock.lock()
        _calls += 1
        lock.unlock()
        return ids
    }
}
