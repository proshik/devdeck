import XCTest
@testable import DevDeck

/// Building the command and the AppleScript that puts it into Ghostty.
/// The scripts are asserted as strings — this is the layer where a quoting slip would run
/// arbitrary text as a command.
final class TabRestorerTests: XCTestCase {

    final class FakeAppleScriptRunner: AppleScriptRunning, @unchecked Sendable {
        var calls: [[String]] = []
        var result = true
        /// Call indices that should fail, for the "keeps going after one failure" case.
        var failingCalls: Set<Int> = []
        func run(_ args: [String]) -> Bool {
            calls.append(args)
            return failingCalls.contains(calls.count - 1) ? false : result
        }
    }

    func testCommandResumesTheSession() {
        XCTAssertEqual(RestoreCommand.text(cwd: "/tmp/a", sessionID: "s1"),
                       "cd '/tmp/a' && claude --resume 's1'")
    }

    func testCommandWithoutSessionOnlyChangesDirectory() {
        XCTAssertEqual(RestoreCommand.text(cwd: "/tmp/a", sessionID: nil), "cd '/tmp/a'")
    }

    func testCommandQuotesAwkwardPaths() {
        XCTAssertEqual(RestoreCommand.text(cwd: "/tmp/it's here", sessionID: nil),
                       #"cd '/tmp/it'\''s here'"#)
    }

    /// The session id is read from a transcript file with a deliberately lenient parser, so it is
    /// untrusted input that ends up typed into a live shell and executed. It gets the same quoting
    /// the working directory does.
    func testCommandQuotesTheSessionID() {
        XCTAssertEqual(RestoreCommand.text(cwd: "/tmp/a", sessionID: "s1; rm -rf ~"),
                       #"cd '/tmp/a' && claude --resume 's1; rm -rf ~'"#)
    }

    /// AppleScript has no "\n" escape — the newline has to be concatenated as `linefeed`,
    /// or the command is typed but never submitted.
    func testNewTabScriptAppendsLinefeedNotBackslashN() {
        let args = RestoreScript.newTabArgs(cwd: "/tmp/a", text: "cd '/tmp/a'")
        XCTAssertTrue(args.contains { $0.contains("& linefeed") })
        XCTAssertFalse(args.contains { $0.contains("\\n\"") })
    }

    func testNewTabScriptSetsDirectoryAndInput() {
        let args = RestoreScript.newTabArgs(cwd: "/tmp/a", text: "cd '/tmp/a'")
        XCTAssertTrue(args.contains("set initial working directory of cfg to \"/tmp/a\""))
        XCTAssertTrue(args.contains("new tab with configuration cfg"))
    }

    func testInputTextScriptTargetsTheFrontWindow() {
        let args = RestoreScript.inputTextArgs(text: "cd '/tmp/a'")
        XCTAssertTrue(args.contains { $0.contains("focused terminal of selected tab of front window") })
    }

    func testInputTextScriptAppendsLinefeedNotBackslashN() {
        let args = RestoreScript.inputTextArgs(text: "cd '/tmp/a'")
        XCTAssertTrue(args.contains { $0.contains("& linefeed") })
        XCTAssertFalse(args.contains { $0.contains("\\n\"") })
    }

    /// The default `providers` — real `ClaudeSessionProvider`/`OpencodeSessionProvider` — never
    /// need to be exercised by these tests: they are about pacing and the AppleScript args, not
    /// about resuming a session, so a session-less action (`sessionID: nil`) never even looks the
    /// provider up.
    private func restorer(runner: AppleScriptRunning, stepDelay: Duration) -> TabRestorer {
        TabRestorer(runner: runner, providers: [FakeAgentProvider(id: "claude")], stepDelay: stepDelay)
    }

    func testRestorerRunsOneScriptPerAction() async {
        let runner = FakeAppleScriptRunner()
        let outcome = await restorer(runner: runner, stepDelay: .zero)
            .restore([.inputText(cwd: "/tmp/a", sessionID: "s1", provider: "claude"),
                      .newTab(cwd: "/tmp/b", sessionID: nil, provider: "claude")])
        XCTAssertEqual(outcome, RestoreOutcome(succeeded: 2, failed: 0))
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertTrue(runner.calls[0].contains { $0.contains("input text") })
        XCTAssertTrue(runner.calls[1].contains("new tab with configuration cfg"))
    }

    func testRestorerReportsFailure() async {
        let runner = FakeAppleScriptRunner()
        runner.result = false
        let outcome = await restorer(runner: runner, stepDelay: .zero)
            .restore([.newTab(cwd: "/tmp/a", sessionID: nil, provider: "claude")])
        XCTAssertEqual(outcome, RestoreOutcome(succeeded: 0, failed: 1))
    }

    /// One failure must not end the restore. Ghostty's spurious errors are real, and a
    /// `guard runner.run(args) else { return false }` would silently drop tabs 2..n — invisible to
    /// a single-action test, and to the user, who would just find half their tabs missing.
    func testRestorerContinuesPastAFailedAction() async {
        let runner = FakeAppleScriptRunner()
        runner.failingCalls = [1]
        let outcome = await restorer(runner: runner, stepDelay: .zero)
            .restore([.newTab(cwd: "/tmp/a", sessionID: "s1", provider: "claude"),
                      .newTab(cwd: "/tmp/b", sessionID: "s2", provider: "claude"),
                      .newTab(cwd: "/tmp/c", sessionID: "s3", provider: "claude")])

        XCTAssertEqual(outcome, RestoreOutcome(succeeded: 2, failed: 1),
                       "a failed action must still be counted, and must not stop the rest")
        XCTAssertEqual(runner.calls.count, 3, "the restore stopped at the first failure")
        XCTAssertTrue(runner.calls[2].contains { $0.contains("/tmp/c") },
                      "the last tab was never attempted")
    }

    /// Every other test in this file uses one provider id throughout, so a `command(cwd:sessionID:
    /// providerID:)` that looked up `providers.first` instead of `providers.first(where: { $0.id ==
    /// providerID })` would pass all of them too. Two providers with different ids, and an action
    /// list that puts the SECOND provider's action first, is what catches that: `providers.first`
    /// would hand every action the first provider's command line regardless of which one it names.
    func testEachActionGetsTheCommandLineOfItsOwnProviderNotTheFirstOne() async {
        let runner = FakeAppleScriptRunner()
        let providers = [FakeAgentProvider(id: "claude"), FakeAgentProvider(id: "opencode")]
        let restorer = TabRestorer(runner: runner, providers: providers, stepDelay: .zero)

        _ = await restorer.restore([.newTab(cwd: "/tmp/a", sessionID: "s1", provider: "opencode"),
                                    .newTab(cwd: "/tmp/b", sessionID: "s2", provider: "claude")])

        let scripts = runner.calls.map { $0.joined(separator: " ") }
        XCTAssertTrue(scripts[0].contains("opencode --resume 's1'"),
                      "the first action named \"opencode\" but got some other provider's command")
        XCTAssertTrue(scripts[1].contains("claude --resume 's2'"),
                      "the second action named \"claude\" but got some other provider's command")
    }

    /// An entry whose `provider` id is not among the ones registered — an old id, a provider that
    /// got removed — must still degrade to a plain shell in the directory, never crash or drop the
    /// tab silently.
    func testUnrecognizedProviderStillOpensAShellInTheDirectory() async {
        let runner = FakeAppleScriptRunner()
        let outcome = await TabRestorer(runner: runner, providers: [], stepDelay: .zero)
            .restore([.newTab(cwd: "/tmp/a", sessionID: "s1", provider: "unknown-agent")])
        XCTAssertEqual(outcome, RestoreOutcome(succeeded: 1, failed: 0))
        XCTAssertTrue(runner.calls[0].contains { $0.contains("cd '/tmp/a'") })
        XCTAssertFalse(runner.calls[0].contains { $0.contains("--resume") || $0.contains("--session") })
    }
}

/// A minimal `AgentSessionProvider` whose `command` just proves which provider `TabRestorer`
/// picked — the AppleScript-args tests above only need to see one script per action, not a real
/// resume command.
struct FakeAgentProvider: AgentSessionProvider {
    var id: String
    var isFallback = false
    func mayOwn(tabTitle: String) -> Bool { true }
    func sessions(inDirectory directory: String) -> [AgentSession] { [] }
    func recentSessions(since: Date) -> [AgentSession] { [] }
    func normalize(tabTitle: String) -> String { tabTitle }
    func command(resuming sessionID: String, in cwd: String) -> String {
        "cd \(shellQuote(cwd)) && \(id) --resume \(shellQuote(sessionID))"
    }
}
