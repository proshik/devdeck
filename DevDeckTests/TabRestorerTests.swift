import XCTest
@testable import DevDeck

/// Building the command and the AppleScript that puts it into Ghostty.
/// The scripts are asserted as strings — this is the layer where a quoting slip would run
/// arbitrary text as a command.
final class TabRestorerTests: XCTestCase {

    final class FakeAppleScriptRunner: AppleScriptRunning, @unchecked Sendable {
        var calls: [[String]] = []
        var result = true
        func run(_ args: [String]) -> Bool { calls.append(args); return result }
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

    func testRestorerRunsOneScriptPerAction() async {
        let runner = FakeAppleScriptRunner()
        let restorer = TabRestorer(runner: runner, stepDelay: .zero)
        let ok = await restorer.restore([.inputText(cwd: "/tmp/a", sessionID: "s1"),
                                         .newTab(cwd: "/tmp/b", sessionID: nil)])
        XCTAssertTrue(ok)
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertTrue(runner.calls[0].contains { $0.contains("input text") })
        XCTAssertTrue(runner.calls[1].contains("new tab with configuration cfg"))
    }

    func testRestorerReportsFailure() async {
        let runner = FakeAppleScriptRunner()
        runner.result = false
        let ok = await TabRestorer(runner: runner, stepDelay: .zero)
            .restore([.newTab(cwd: "/tmp/a", sessionID: nil)])
        XCTAssertFalse(ok)
    }
}
