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

    func testScriptStartsWithAnExecutableShebang() {
        // `.custom` templates hand the path straight to execvp (`wezterm start -- <path>`,
        // `kitty <path>`). Without a shebang execvp silently falls back to /bin/sh, where `print -P`
        // doesn't exist and the stay-open `exec` would pick the wrong shell — a failure that shows
        // up only as a lost footer, or as a 30-second hang when the mode is 0644 as well.
        let command = Command(id: UUID(), name: "c", command: "x", openInTerminal: true)
        let script = GhosttyCommandRunner.script(command,
                                                 pidFile: URL(fileURLWithPath: "/tmp/p"),
                                                 exitFile: URL(fileURLWithPath: "/tmp/e"))
        XCTAssertTrue(script.hasPrefix("#!/bin/zsh -l\n"), "got: \(script.prefix(40))")
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

    // MARK: custom launch command

    func testExpandSubstitutesTheQuotedScriptPath() {
        let expanded = expandTerminalLaunchCommand(template: "wezterm start -- {script}",
                                                   scriptPath: "/tmp/run.zsh")
        XCTAssertEqual(expanded, "wezterm start -- '/tmp/run.zsh'")
    }

    func testExpandQuotesAPathWithSpaces() {
        // The path is ours (a temp dir), but the user's home may contain spaces.
        let expanded = expandTerminalLaunchCommand(template: "open -a iTerm {script}",
                                                   scriptPath: "/Users/a b/run.zsh")
        XCTAssertEqual(expanded, "open -a iTerm '/Users/a b/run.zsh'")
    }

    func testExpandRejectsATemplateWithoutThePlaceholder() {
        // The terminal would open with nothing to run, and the failure would look like a hang.
        XCTAssertNil(expandTerminalLaunchCommand(template: "wezterm start", scriptPath: "/tmp/r"))
    }

    func testExpandRejectsABlankTemplate() {
        XCTAssertNil(expandTerminalLaunchCommand(template: "", scriptPath: "/tmp/r"))
        XCTAssertNil(expandTerminalLaunchCommand(template: "   \n", scriptPath: "/tmp/r"))
    }

    func testModeSelectorRoutesToTheCustomLauncher() async throws {
        let win = RecordingLauncher()
        let tab = RecordingLauncher()
        let custom = RecordingLauncher()
        let url = URL(fileURLWithPath: "/tmp/run.zsh")

        try await ModeSelectingLauncher(window: win, tab: tab, custom: custom, mode: { .custom })
            .launch(scriptURL: url)

        XCTAssertEqual(custom.launched, [url])
        XCTAssertEqual(win.launched, [])
        XCTAssertEqual(tab.launched, [])
    }

    func testCustomLauncherRefusesATemplateItCannotUse() async {
        // No {script} to substitute → fail loudly at launch, not by burning the 30-second timeout.
        do {
            try await CustomCommandLauncher(template: { "" })
                .launch(scriptURL: URL(fileURLWithPath: "/tmp/run.zsh"))
            XCTFail("a blank template must not launch anything")
        } catch let error as TerminalLauncherError {
            XCTAssertEqual(error.message, L10n.terminalCustomCommandInvalid)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: whole runs against a temp base directory

    /// A private base directory for one run; the runner creates `devdeck-term-*` inside it.
    private func makeBaseDir() throws -> URL {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base
    }

    private func drain(_ process: any RunningProcess) async -> [RunnerOutput] {
        var events: [RunnerOutput] = []
        for await event in process.output { events.append(event) }
        return events
    }

    private var terminalCommand: Command {
        Command(id: UUID(), name: "c", command: "true", openInTerminal: true)
    }

    private func runDirectories(in base: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("devdeck-term-") }
    }

    func testTheWrittenScriptFileIsExecutable() async throws {
        let base = try makeBaseDir()
        let launcher = RecordingLauncher()
        let runner = GhosttyCommandRunner(launcher: launcher, baseDir: base,
                                          pollInterval: .milliseconds(1), maxStartupTicks: 1)
        _ = await drain(runner.start(terminalCommand))

        let script = try XCTUnwrap(launcher.launched.first)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path),
                      "a custom launcher execs this path directly — 0644 fails with EACCES")
        let mode = try FileManager.default.attributesOfItem(atPath: script.path)[.posixPermissions]
        XCTAssertEqual((mode as? NSNumber)?.intValue, 0o755)
    }

    func testRunDirectorySurvivesAFinishedRun() async throws {
        // The point of the branch: cleanup at the terminal event is gone — the tab may still be a
        // live shell, and its script stays around for diagnosing. The launch sweep owns cleanup now.
        let base = try makeBaseDir()
        let runner = GhosttyCommandRunner(launcher: SentinelWritingLauncher(exitCode: 0),
                                          baseDir: base, pollInterval: .milliseconds(1))
        let events = await drain(runner.start(terminalCommand))

        XCTAssertEqual(events.last, .terminated(exitCode: 0))
        let dir = try XCTUnwrap(runDirectories(in: base).first, "the run directory was deleted")
        XCTAssertTrue(FileManager.default
            .fileExists(atPath: dir.appendingPathComponent("run.zsh").path),
                      "the wrapper script must outlive the run")
    }

    func testRunDirectoryIsRemovedWhenTheLaunchFails() async throws {
        // The one deletion that stays: no terminal ever received this script.
        let base = try makeBaseDir()
        let runner = GhosttyCommandRunner(launcher: FailingLauncher(), baseDir: base,
                                          pollInterval: .milliseconds(1))
        let events = await drain(runner.start(terminalCommand))

        XCTAssertEqual(events.last, .terminated(exitCode: 127))
        XCTAssertEqual(runDirectories(in: base), [])
    }

    func testStartupTimeoutBlamesGhosttyInGhosttyModes() async throws {
        let base = try makeBaseDir()
        let runner = GhosttyCommandRunner(launcher: RecordingLauncher(), baseDir: base,
                                          pollInterval: .milliseconds(1), maxStartupTicks: 1,
                                          launchMode: { .window })
        let events = await drain(runner.start(terminalCommand))

        XCTAssertTrue(events.contains(.line(L10n.terminalDidNotStart, stream: .stderr)))
        XCTAssertEqual(events.last, .terminated(exitCode: 127))
    }

    func testStartupTimeoutBlamesTheCustomCommandInCustomMode() async throws {
        // The custom launch is deliberately not waited on, so this timeout is its ONLY failure
        // channel — pointing at Ghostty's permissions would misdiagnose every typo'd binary.
        let base = try makeBaseDir()
        let runner = GhosttyCommandRunner(launcher: RecordingLauncher(), baseDir: base,
                                          pollInterval: .milliseconds(1), maxStartupTicks: 1,
                                          launchMode: { .custom })
        let events = await drain(runner.start(terminalCommand))

        XCTAssertTrue(events.contains(.line(L10n.terminalCustomDidNotStart, stream: .stderr)))
        XCTAssertFalse(events.contains(.line(L10n.terminalDidNotStart, stream: .stderr)))
    }
}

/// Fake launcher: records launches without invoking a real terminal.
final class RecordingLauncher: TerminalLauncher, @unchecked Sendable {
    private(set) var launched: [URL] = []
    func launch(scriptURL: URL) async throws { launched.append(scriptURL) }
}

/// Fake launcher standing in for a terminal that ran the script to completion: writes the two
/// sentinels the runner polls for, without a terminal or a real process.
struct SentinelWritingLauncher: TerminalLauncher {
    let exitCode: Int32

    func launch(scriptURL: URL) async throws {
        let dir = scriptURL.deletingLastPathComponent()
        try "\(ProcessInfo.processInfo.processIdentifier)\n"
            .write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        try "\(exitCode)\n"
            .write(to: dir.appendingPathComponent("exit"), atomically: true, encoding: .utf8)
    }
}

/// Fake launcher for the failure path (no terminal installed, AppleScript refused, …).
struct FailingLauncher: TerminalLauncher {
    func launch(scriptURL: URL) async throws {
        throw TerminalLauncherError(message: "no terminal")
    }
}
