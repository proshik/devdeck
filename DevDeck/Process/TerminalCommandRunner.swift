import Foundation
import AppKit

// MARK: - Pure tracking logic

/// Turns observations (PID, exit code, whether the PID is alive) into `RunnerOutput` stream events.
/// A one-shot `.started`, then exactly one terminal event. Written without timers/files → unit-testable.
struct TerminalTracker {
    private(set) var startedEmitted = false
    private(set) var finished = false

    mutating func tick(pid: Int32?, exitCode: Int32?, pidAlive: Bool) -> [RunnerOutput] {
        guard !finished else { return [] }
        var events: [RunnerOutput] = []
        if let pid, !startedEmitted {
            startedEmitted = true
            events.append(.started(pid: pid))
        }
        if let exitCode {                       // the wrapper wrote a code → a normal terminal event
            finished = true
            events.append(.terminated(exitCode: exitCode))
        } else if startedEmitted, !pidAlive {   // PID died without a code (tab closed) → terminal event
            finished = true
            events.append(.terminated(exitCode: 143))
        }
        return events
    }
}

// MARK: - Launching Ghostty

struct TerminalLauncherError: Error { let message: String }

/// The seam for launching a script in the terminal — behind a protocol so the runner is tested without Ghostty.
protocol TerminalLauncher: Sendable {
    /// Open the script in Ghostty. Throws if Ghostty is missing or fails to launch.
    func launch(scriptURL: URL) async throws
}

private let ghosttyAppURL = URL(fileURLWithPath: "/Applications/Ghostty.app")

/// Launches Ghostty as a NEW instance via the native `NSWorkspace.openApplication`
/// (passing `-e /bin/zsh -l <script>` as arguments). The shell `open` from a GUI app
/// proved unreliable (Ghostty wouldn't start the script), so we use the Cocoa API.
/// Always a new instance/window: you can't inject a command into a tab of an already-running Ghostty from the CLI/API.
struct GhosttyLauncher: TerminalLauncher {
    func launch(scriptURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: ghosttyAppURL.path) else {
            throw TerminalLauncherError(message: L10n.ghosttyNotFound)
        }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        config.arguments = ["-e", "/bin/zsh", "-l", scriptURL.path]
        DiagnosticLog.shared.log("Terminal: launching Ghostty (window) for \(scriptURL.lastPathComponent)")
        do {
            _ = try await NSWorkspace.shared.openApplication(at: ghosttyAppURL, configuration: config)
        } catch {
            DiagnosticLog.shared.log("Terminal: openApplication error — \(error.localizedDescription)", level: .error)
            throw TerminalLauncherError(message: error.localizedDescription)
        }
    }
}

/// Terminal launch mode (chosen in the UI, stored in UserDefaults).
enum TerminalLaunchMode: String {
    case window   // a new Ghostty window/instance (reliable, no permissions)
    case tab      // a new tab via Ghostty's native AppleScript (needs "Automation")
    case custom   // the user's own command line — any terminal, including ones we've never heard of
    static let key = "terminalLaunchMode"
    /// UserDefaults key for the `.custom` template. Beside `key` on purpose: the two are one
    /// setting in the user's mind, and splitting them across stores would make neither the source
    /// of truth.
    static let commandKey = "terminalLaunchCommand"
}

/// Substitute the wrapper script's path into the user's template. Pure.
///
/// nil when the template cannot work — blank, or missing the `{script}` placeholder. Rejecting it
/// here matters: a terminal launched with nothing to run looks exactly like DevDeck hanging, and the
/// user would wait out the 30-second startup timeout to learn about a typo.
func expandTerminalLaunchCommand(template: String, scriptPath: String) -> String? {
    let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.contains("{script}") else { return nil }
    return trimmed.replacingOccurrences(of: "{script}",
                                        with: GhosttyCommandRunner.shQuote(scriptPath))
}

/// Launches in a NEW TAB via Ghostty's NATIVE AppleScript (`new tab with configuration`,
/// surface `command`). No Accessibility needed — only "Automation" (controlling Ghostty),
/// which is requested automatically. If Ghostty isn't running, the first launch opens a window
/// (via the same window-launcher); subsequent ones open tabs in it.
/// (`try` swallows Ghostty's spurious -1708 error, which arrives when the result is returned
///  even though the tab is already created and the command is running.)
struct AppleScriptTabLauncher: TerminalLauncher {
    let windowLauncher = GhosttyLauncher()

    func launch(scriptURL: URL) async throws {
        guard FileManager.default.fileExists(atPath: ghosttyAppURL.path) else {
            throw TerminalLauncherError(message: L10n.ghosttyNotFound)
        }
        let running = !(ProcessTree.run("/usr/bin/pgrep", ["-x", "ghostty"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard running else {
            // not running → first window (also tracked); subsequent ones go to tabs
            DiagnosticLog.shared.log("Terminal: Ghostty not running → first window (tabs afterwards)")
            try await windowLauncher.launch(scriptURL: scriptURL)
            return
        }
        DiagnosticLog.shared.log("Terminal: new tab (Ghostty AppleScript)")
        let command = "/bin/zsh -l \(GhosttyCommandRunner.shQuote(scriptURL.path))"
        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = Self.osascriptArgs(command: command)
        let err = Pipe(); osa.standardError = err
        try osa.run(); osa.waitUntilExit()
        guard osa.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DiagnosticLog.shared.log("Terminal: AppleScript error — \(msg)", level: .error)
            throw TerminalLauncherError(message: L10n.terminalTabFailed(msg))
        }
    }

    /// osascript: create a surface config with `command` → open a tab with it (`try` swallows -1708).
    static func osascriptArgs(command: String) -> [String] {
        let c = escape(command)
        return [
            "-e", "tell application \"Ghostty\"",
            "-e", "set cfg to new surface configuration",
            "-e", "set command of cfg to \"\(c)\"",
            "-e", "try",
            "-e", "new tab with configuration cfg",
            "-e", "end try",
            "-e", "end tell",
        ]
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }
}

/// Launches through the user's own command line — any terminal, including ones that don't exist yet.
///
/// Run via `zsh -lc` rather than a hand-rolled argv split: the user gets the full shell syntax, and
/// `-l` picks up their PATH from `.zshrc`, so `wezterm` resolves without an absolute path — exactly
/// how every other command in this app is launched.
///
/// Deliberately NOT waited on. A terminal that stays in the foreground (`alacritty -e` does) would
/// otherwise block the caller before polling ever starts, leaving the command stuck in `running`
/// forever. A template that fails inside zsh is caught by the runner's startup timeout instead.
struct CustomCommandLauncher: TerminalLauncher {
    let template: @Sendable () -> String

    init(template: @escaping @Sendable () -> String = {
        UserDefaults.standard.string(forKey: TerminalLaunchMode.commandKey) ?? ""
    }) {
        self.template = template
    }

    func launch(scriptURL: URL) async throws {
        guard let command = expandTerminalLaunchCommand(template: template(),
                                                        scriptPath: scriptURL.path) else {
            throw TerminalLauncherError(message: L10n.terminalCustomCommandInvalid)
        }
        DiagnosticLog.shared.log("Terminal: custom launch — \(command)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        do {
            try process.run()   // not waited on — see the note above
        } catch {
            DiagnosticLog.shared.log("Terminal: custom launch failed — \(error.localizedDescription)",
                                     level: .error)
            throw TerminalLauncherError(message: L10n.terminalLaunchFailed(error.localizedDescription))
        }
    }
}

/// Picks a launcher by the current mode (UserDefaults) on EVERY launch — switching
/// in the UI takes effect immediately, without recreating the runners.
struct ModeSelectingLauncher: TerminalLauncher {
    let window: any TerminalLauncher
    let tab: any TerminalLauncher
    let custom: any TerminalLauncher
    let mode: @Sendable () -> TerminalLaunchMode

    init(
        window: any TerminalLauncher = GhosttyLauncher(),
        tab: any TerminalLauncher = AppleScriptTabLauncher(),
        custom: any TerminalLauncher = CustomCommandLauncher(),
        mode: @escaping @Sendable () -> TerminalLaunchMode = {
            TerminalLaunchMode(rawValue: UserDefaults.standard.string(forKey: TerminalLaunchMode.key) ?? "")
                ?? .window
        }
    ) {
        self.window = window
        self.tab = tab
        self.custom = custom
        self.mode = mode
    }

    func launch(scriptURL: URL) async throws {
        switch mode() {
        case .tab: try await tab.launch(scriptURL: scriptURL)
        case .window: try await window.launch(scriptURL: scriptURL)
        case .custom: try await custom.launch(scriptURL: scriptURL)
        }
    }
}

/// Delete run directories left over by previous sessions.
///
/// The runner deliberately does NOT delete a directory when the command finishes: zsh reads the
/// wrapper script incrementally and is still executing its last lines at that moment, so removing it
/// underneath is a race — and losing it closes the tab, which is precisely what `keepTerminalOpen`
/// exists to prevent. Cleaning up at launch is safe instead, because a tab that is still running is
/// detectable: its `pid` sentinel names a live process.
///
/// `isAlive` is injected so the decision is testable without real processes.
func sweepStaleTerminalDirectories(
    in baseDir: URL = FileManager.default.temporaryDirectory,
    isAlive: (Int32) -> Bool = { ProcessTree.isAlive($0) }
) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil)
    else { return }
    for dir in entries where dir.lastPathComponent.hasPrefix("devdeck-term-") {
        let pidText = try? String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8)
        let pid = pidText.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        // A live pid means a tab from a previous session is still running this script.
        if let pid, isAlive(pid) { continue }
        try? fm.removeItem(at: dir)
    }
}

// MARK: - Terminal runner

/// Runs a command in a Ghostty tab and tracks it via sentinel files (PID/exit code),
/// emitting the same `RunnerOutput` as the regular runners → `ProcessManager` is unchanged.
struct GhosttyCommandRunner: CommandRunner {
    let launcher: any TerminalLauncher
    let baseDir: URL
    let pollInterval: Duration
    /// How many ticks to wait for `.started` (the PID file) before giving up — guards against a "silent"
    /// launch (no Ghostty/Accessibility). 100 × 300ms ≈ 30s.
    let maxStartupTicks: Int
    let killTree: @Sendable (Int32) -> Void
    let isAlive: @Sendable (Int32) -> Bool

    init(
        launcher: any TerminalLauncher = ModeSelectingLauncher(),
        baseDir: URL = FileManager.default.temporaryDirectory,
        pollInterval: Duration = .milliseconds(300),
        maxStartupTicks: Int = 100,
        killTree: @escaping @Sendable (Int32) -> Void = { ProcessTree.terminate($0) },
        isAlive: @escaping @Sendable (Int32) -> Bool = { ProcessTree.isAlive($0) }
    ) {
        self.launcher = launcher
        self.baseDir = baseDir
        self.pollInterval = pollInterval
        self.maxStartupTicks = maxStartupTicks
        self.killTree = killTree
        self.isAlive = isAlive
    }

    func start(_ command: Command) -> any RunningProcess {
        let dir = baseDir.appendingPathComponent("devdeck-term-\(UUID().uuidString)")
        return GhosttyRunningProcess(
            command: command, dir: dir, launcher: launcher, pollInterval: pollInterval,
            maxStartupTicks: maxStartupTicks, killTree: killTree, isAlive: isAlive)
    }

    /// Wrapper script: shebang → cd/env → write PID → command → write code → pause on "Press Enter to close".
    ///
    /// The shebang is load-bearing for `.custom`: templates like `wezterm start -- {script}` or
    /// `kitty {script}` `execvp` the path directly, and without `#!` the kernel refuses it with
    /// "Exec format error". (The Ghostty launchers hand the file to an explicit interpreter,
    /// `zsh -l <script>`, for which the line is just a comment.) macOS passes everything after the
    /// interpreter path as ONE argument, so `-l` is a single valid flag here.
    /// The file is written with mode 0755 for the same reason — see `GhosttyRunningProcess`.
    static func script(_ command: Command, pidFile: URL, exitFile: URL) -> String {
        var lines: [String] = ["#!/bin/zsh -l"]
        if let wd = command.workingDirectory, !wd.isEmpty {
            lines.append("cd \(shQuote(wd)) || exit 127")
        }
        for (key, value) in command.env.sorted(by: { $0.key < $1.key }) {
            lines.append("export \(key)=\(shQuote(value))")
        }
        lines.append("echo $$ > \(shQuote(pidFile.path))")
        lines.append(command.needsSudo ? "sudo \(command.command)" : command.command)
        lines.append("code=$?")
        lines.append("echo $code > \(shQuote(exitFile.path))")
        lines.append("echo")
        if command.keepTerminalOpen {
            lines.append("print -P \"%F{8}\(L10n.terminalStaysOpenFooter("$code"))%f\"")
            // `exec` replaces this shell in place, so the tab becomes an ordinary login shell in the
            // same directory with the command's environment still exported. The exit sentinel is
            // written above, so DevDeck has already reported the real exit code by the time this runs.
            lines.append("exec \"${SHELL:-/bin/zsh}\" -l")
        } else {
            lines.append("print -P \"%F{8}\(L10n.terminalDoneFooter("$code"))%f\"")
            lines.append("read")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    static func shQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// Handle for a terminal run: prepares the script, launches Ghostty, polls the sentinels.
final class GhosttyRunningProcess: RunningProcess, @unchecked Sendable {
    let token = UUID()
    let output: AsyncStream<RunnerOutput>
    private let lock = NSLock()
    private var pid: Int32?
    private let killTree: @Sendable (Int32) -> Void

    init(
        command: Command,
        dir: URL,
        launcher: any TerminalLauncher,
        pollInterval: Duration,
        maxStartupTicks: Int,
        killTree: @escaping @Sendable (Int32) -> Void,
        isAlive: @escaping @Sendable (Int32) -> Bool
    ) {
        self.killTree = killTree
        let (stream, cont) = AsyncStream.makeStream(of: RunnerOutput.self, bufferingPolicy: .unbounded)
        self.output = stream

        let pidFile = dir.appendingPathComponent("pid")
        let exitFile = dir.appendingPathComponent("exit")
        let scriptFile = dir.appendingPathComponent("run.zsh")
        let script = GhosttyCommandRunner.script(command, pidFile: pidFile, exitFile: exitFile)

        Task.detached { [weak self, cont] in
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try script.write(to: scriptFile, atomically: true, encoding: .utf8)
                // Executable, because a `.custom` template may hand the path straight to `execvp`
                // (`wezterm start -- <path>`, `kitty <path>`): without +x that fails with
                // "Permission denied", and the user only sees a 30-second hang.
                try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                      ofItemAtPath: scriptFile.path)
                try await launcher.launch(scriptURL: scriptFile)
            } catch {
                let msg = (error as? TerminalLauncherError)?.message ?? error.localizedDescription
                cont.yield(.line(L10n.terminalLaunchFailed(msg), stream: .stderr))
                cont.yield(.terminated(exitCode: 127))
                cont.finish()
                // Safe to delete here and only here: the launch failed, so no interpreter ever
                // received this script. The other exits leave it to the startup sweep.
                try? FileManager.default.removeItem(at: dir)
                return
            }
            var tracker = TerminalTracker()
            var startupTicks = 0
            while true {
                let pid = Self.readInt(pidFile)
                let exit = Self.readInt(exitFile)
                if let pid { self?.setPID(pid) }
                let alive = pid.map(isAlive) ?? true
                for event in tracker.tick(pid: pid, exitCode: exit, pidAlive: alive) { cont.yield(event) }
                if tracker.finished {
                    cont.finish()
                    return
                }
                if !tracker.startedEmitted {   // hasn't started yet → guard timeout
                    startupTicks += 1
                    if startupTicks >= maxStartupTicks {
                        cont.yield(.line(L10n.terminalDidNotStart, stream: .stderr))
                        cont.yield(.terminated(exitCode: 127))
                        cont.finish()
                        return
                    }
                }
                try? await Task.sleep(for: pollInterval)
            }
        }
    }

    private func setPID(_ p: Int32) { lock.lock(); pid = p; lock.unlock() }

    /// Stop: kill the PID's subtree. The terminal event comes from polling (PID dies without an exit file → `.terminated(143)`).
    func stop() {
        lock.lock(); let p = pid; lock.unlock()
        if let p { killTree(p) }
    }

    private static func readInt(_ url: URL) -> Int32? {
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
