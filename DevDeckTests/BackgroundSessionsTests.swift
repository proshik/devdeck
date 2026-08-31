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
}

/// No process is ever spawned in tests — the live listing shells out to `claude agents --json`.
struct FakeBackgroundSessions: BackgroundSessionListing {
    let ids: Set<String>
    func backgroundSessionIDs() -> Set<String> { ids }
}
