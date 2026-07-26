import XCTest
@testable import DevDeck

final class TerminalRunnerTests: XCTestCase {

    // MARK: TerminalTracker — pure event logic

    func testStartedThenCleanExit() {
        var t = TerminalTracker()
        XCTAssertEqual(t.tick(pid: nil, exitCode: nil, pidAlive: true), [])          // no PID yet
        XCTAssertEqual(t.tick(pid: 100, exitCode: nil, pidAlive: true), [.started(pid: 100)])
        XCTAssertEqual(t.tick(pid: 100, exitCode: nil, pidAlive: true), [])          // repeated tick — silent
        XCTAssertEqual(t.tick(pid: 100, exitCode: 0, pidAlive: true), [.terminated(exitCode: 0)])
        XCTAssertTrue(t.finished)
        XCTAssertEqual(t.tick(pid: 100, exitCode: 0, pidAlive: true), [])            // after terminal — silent
    }

    func testExitCodePreserved() {
        var t = TerminalTracker()
        _ = t.tick(pid: 7, exitCode: nil, pidAlive: true)
        XCTAssertEqual(t.tick(pid: 7, exitCode: 137, pidAlive: false), [.terminated(exitCode: 137)])
    }

    func testPidDeathWithoutExitTerminates() {
        // Closed the Ghostty tab → process died, exit file not written → terminal 143.
        var t = TerminalTracker()
        _ = t.tick(pid: 200, exitCode: nil, pidAlive: true)
        XCTAssertEqual(t.tick(pid: 200, exitCode: nil, pidAlive: false), [.terminated(exitCode: 143)])
        XCTAssertTrue(t.finished)
    }

    func testPidAndExitSameTickEmitsBoth() {
        // Polling observed both PID and exit code in one tick → started before terminated (stream invariant).
        var t = TerminalTracker()
        XCTAssertEqual(t.tick(pid: 5, exitCode: 0, pidAlive: true),
                       [.started(pid: 5), .terminated(exitCode: 0)])
    }

    func testNoFalseTerminateBeforeStart() {
        // PID has not appeared yet (alive=true by default) → neither started nor terminal.
        var t = TerminalTracker()
        XCTAssertEqual(t.tick(pid: nil, exitCode: nil, pidAlive: true), [])
        XCTAssertFalse(t.finished)
    }

    // MARK: script wrapper

    func testScriptWritesPidRunsCommandWritesExit() {
        let pid = URL(fileURLWithPath: "/tmp/p")
        let exit = URL(fileURLWithPath: "/tmp/e")
        let command = Command(id: UUID(), name: "c", command: "just dev-start",
                              workingDirectory: "/work", env: ["A": "1"], openInTerminal: true)
        let script = GhosttyCommandRunner.script(command, pidFile: pid, exitFile: exit)

        XCTAssertTrue(script.contains("cd '/work'"))
        XCTAssertTrue(script.contains("export A='1'"))
        XCTAssertTrue(script.contains("echo $$ > '/tmp/p'"))
        XCTAssertTrue(script.contains("just dev-start"))
        XCTAssertTrue(script.contains("echo $code > '/tmp/e'"))
    }

    func testScriptPrefixesSudo() {
        let command = Command(id: UUID(), name: "c", command: "purge",
                              needsSudo: true, openInTerminal: true)
        let script = GhosttyCommandRunner.script(command,
                                                 pidFile: URL(fileURLWithPath: "/tmp/p"),
                                                 exitFile: URL(fileURLWithPath: "/tmp/e"))
        XCTAssertTrue(script.contains("sudo purge"))
    }

    func testScriptWaitsForEnterByDefault() {
        let command = Command(id: UUID(), name: "build", command: "just build", openInTerminal: true)
        let script = GhosttyCommandRunner.script(
            command,
            pidFile: URL(fileURLWithPath: "/tmp/p"), exitFile: URL(fileURLWithPath: "/tmp/e"))

        XCTAssertTrue(script.hasSuffix("read\n"), "unchanged default — the tab closes on Enter")
        XCTAssertFalse(script.contains("exec "))
    }

    func testScriptHandsTheTabToAShellWhenAsked() {
        let command = Command(id: UUID(), name: "claude", command: "claude",
                              openInTerminal: true, keepTerminalOpen: true)
        let script = GhosttyCommandRunner.script(
            command,
            pidFile: URL(fileURLWithPath: "/tmp/p"), exitFile: URL(fileURLWithPath: "/tmp/e"))

        XCTAssertTrue(script.contains("exec \"${SHELL:-/bin/zsh}\" -l"))
        XCTAssertFalse(script.contains("\nread\n"), "waiting for Enter would defeat the point")

        // The tracker reports the command's exit code from this sentinel. Writing it AFTER handing
        // the tab over would mean it never gets written at all.
        let exitWrite = try! XCTUnwrap(script.range(of: "> '/tmp/e'"))
        let exec = try! XCTUnwrap(script.range(of: "exec \""))
        XCTAssertTrue(exitWrite.upperBound < exec.lowerBound,
                      "the exit sentinel must be written before the exec")
    }

    // MARK: mode selection and AppleScript

    func testModeSelectorRoutesToWindowOrTab() async throws {
        let win = RecordingLauncher()
        let tab = RecordingLauncher()
        let url = URL(fileURLWithPath: "/tmp/s.zsh")

        try await ModeSelectingLauncher(window: win, tab: tab, mode: { .window }).launch(scriptURL: url)
        try await ModeSelectingLauncher(window: win, tab: tab, mode: { .tab }).launch(scriptURL: url)

        XCTAssertEqual(win.launched, [url])
        XCTAssertEqual(tab.launched, [url])
    }

    func testOsascriptArgsBuildNewTabWithCommand() {
        let args = AppleScriptTabLauncher.osascriptArgs(command: "/bin/zsh -l '/tmp/s.zsh'")
        let joined = args.joined(separator: "\n")
        XCTAssertTrue(joined.contains("new surface configuration"))
        XCTAssertTrue(joined.contains("set command of cfg to \"/bin/zsh -l '/tmp/s.zsh'\""))
        XCTAssertTrue(joined.contains("new tab with configuration cfg"))
        XCTAssertTrue(joined.contains("try"))   // suppresses the spurious -1708 error
    }

    func testAppleScriptEscape() {
        XCTAssertEqual(AppleScriptTabLauncher.escape("\""), "\\\"")
        XCTAssertEqual(AppleScriptTabLauncher.escape("\\"), "\\\\")
    }

    // MARK: model

    func testOpenInTerminalRoundTrips() throws {
        let command = Command(id: UUID(), name: "c", command: "x", openInTerminal: true)
        let data = try JSONEncoder().encode(command)
        let decoded = try JSONDecoder().decode(Command.self, from: data)
        XCTAssertTrue(decoded.openInTerminal)
    }

    func testOpenInTerminalDefaultsFalseWhenAbsent() throws {
        // Old config without the field → false (backward compatibility).
        let json = #"{"id":"\#(UUID().uuidString)","name":"c","command":"x"}"#
        let decoded = try JSONDecoder().decode(Command.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.openInTerminal)
    }

    // MARK: stale run-directory sweep

    /// Build a fake run directory; `pid` nil means the wrapper never started.
    private func makeRunDir(_ base: URL, _ name: String, pid: Int32?) throws -> URL {
        let dir = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let pid {
            try "\(pid)\n".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testSweepRemovesFinishedRunsAndKeepsLiveOnes() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let live = try makeRunDir(base, "devdeck-term-live", pid: 4242)
        let dead = try makeRunDir(base, "devdeck-term-dead", pid: 1)
        let never = try makeRunDir(base, "devdeck-term-never", pid: nil)
        let foreign = try makeRunDir(base, "someone-elses-dir", pid: nil)

        sweepStaleTerminalDirectories(in: base, isAlive: { $0 == 4242 })

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: live.path),
                      "a tab still running from a previous session must keep its script")
        XCTAssertFalse(fm.fileExists(atPath: dead.path), "its terminal is gone — nothing can read it")
        XCTAssertFalse(fm.fileExists(atPath: never.path), "no pid sentinel means it never started")
        XCTAssertTrue(fm.fileExists(atPath: foreign.path),
                      "only our own devdeck-term-* directories are ours to delete")
    }

    func testSweepToleratesAnUnreadableBaseDirectory() {
        // Must not throw or trap when the temp directory can't be listed.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-absent-\(UUID().uuidString)")
        sweepStaleTerminalDirectories(in: missing, isAlive: { _ in false })
    }
}

/// Fake launcher: records launches without invoking a real terminal.
final class RecordingLauncher: TerminalLauncher, @unchecked Sendable {
    private(set) var launched: [URL] = []
    func launch(scriptURL: URL) async throws { launched.append(scriptURL) }
}
