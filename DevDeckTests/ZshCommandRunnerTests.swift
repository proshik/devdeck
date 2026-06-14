import XCTest
@testable import DevDeck

/// Integration tests for the real `ZshCommandRunner` (launch live processes).
final class ZshCommandRunnerTests: XCTestCase {

    private func command(_ cmd: String, cwd: String? = nil) -> Command {
        Command(id: UUID(), name: "t", command: cmd, workingDirectory: cwd)
    }

    func testRealEchoSucceeds() async {
        let handle = ZshCommandRunner().start(command("echo hi"))
        let events = await collectEvents(handle)

        XCTAssertTrue(events.contains(.line("hi", stream: .stdout)), "events: \(events)")
        XCTAssertEqual(events.last, .terminated(exitCode: 0))
    }

    func testRealExitCodeFidelity() async {
        let handle = ZshCommandRunner().start(command("exit 3"))
        let events = await collectEvents(handle)
        XCTAssertEqual(events.last, .terminated(exitCode: 3))
    }

    func testPartialLineFlushedAtEOF() async {
        // stdout = "a" + "b\nc" = "ab\nc" → lines ["ab", "c"] (trailing data without \n is flushed at EOF).
        let handle = ZshCommandRunner().start(command(#"printf 'a'; printf 'b\nc'"#))
        let events = await collectEvents(handle)
        XCTAssertEqual(lines(events, .stdout), ["ab", "c"])
        XCTAssertEqual(events.last, .terminated(exitCode: 0))
    }

    func testStdoutStderrTagging() async {
        let handle = ZshCommandRunner().start(command("echo out; echo err 1>&2"))
        let events = await collectEvents(handle)
        XCTAssertEqual(lines(events, .stdout), ["out"])
        XCTAssertEqual(lines(events, .stderr), ["err"])
    }

    func testBadWorkingDirectoryFailsNotCrash() async {
        let handle = ZshCommandRunner().start(command("echo hi", cwd: "/no/such/dir/xyz-\(UUID().uuidString)"))
        let events = await collectEvents(handle)
        XCTAssertEqual(events.last, .terminated(exitCode: 127), "bad cwd → 127 without an ObjC crash")
    }

    func testTerminalArrivesEvenWhenBackgroundChildHoldsPipe() async {
        // zsh prints hi and exits, but the background sleep inherits the stdout pipe and holds it
        // open for ~5 s. Without force-finish, the terminal event would not arrive until the grandchild exits (hang).
        let handle = ZshCommandRunner().start(command("echo hi; sleep 5 &"))
        let events = await collectEvents(handle, timeout: 3)

        XCTAssertTrue(events.contains(.line("hi", stream: .stdout)), "events: \(events)")
        XCTAssertEqual(events.last, .terminated(exitCode: 0), "terminal is forced by the grace period, does not wait for the grandchild")
    }

    func testStopTerminatesRunningProcess() async {
        let handle = ZshCommandRunner().start(command("sleep 30"))
        // Stop as soon as we know the process is alive (.started ⇒ pid assigned).
        let collector = Task { () -> [RunnerOutput] in
            var events: [RunnerOutput] = []
            for await event in handle.output {
                events.append(event)
                if case .started = event { handle.stop() }
            }
            return events
        }
        let events = await collector.value
        guard case .terminated(let code)? = events.last else {
            return XCTFail("no terminal event: \(events)")
        }
        XCTAssertTrue(code == 143 || code == 137, "SIGTERM(143) or SIGKILL escalation(137), got \(code)")
    }
}
