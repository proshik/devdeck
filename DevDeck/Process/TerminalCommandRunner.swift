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

/// Terminal launch mode (toggled in the UI, stored in UserDefaults).
enum TerminalLaunchMode: String {
    case window   // a new Ghostty window/instance (reliable, no permissions)
    case tab      // a new tab via Ghostty's native AppleScript (needs "Automation")
    static let key = "terminalLaunchMode"
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

/// Picks a launcher by the current mode (UserDefaults) on EVERY launch — switching
/// in the UI takes effect immediately, without recreating the runners.
struct ModeSelectingLauncher: TerminalLauncher {
    let window: any TerminalLauncher
    let tab: any TerminalLauncher
    let mode: @Sendable () -> TerminalLaunchMode

    init(
        window: any TerminalLauncher = GhosttyLauncher(),
        tab: any TerminalLauncher = AppleScriptTabLauncher(),
        mode: @escaping @Sendable () -> TerminalLaunchMode = {
            TerminalLaunchMode(rawValue: UserDefaults.standard.string(forKey: TerminalLaunchMode.key) ?? "")
                ?? .window
        }
    ) {
        self.window = window
        self.tab = tab
        self.mode = mode
    }

    func launch(scriptURL: URL) async throws {
        switch mode() {
        case .tab: try await tab.launch(scriptURL: scriptURL)
        case .window: try await window.launch(scriptURL: scriptURL)
        }
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

    /// Wrapper script: cd/env → write PID → command → write code → pause on "Press Enter to close".
    static func script(_ command: Command, pidFile: URL, exitFile: URL) -> String {
        var lines: [String] = []
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
        lines.append("print -P \"%F{8}\(L10n.terminalDoneFooter("$code"))%f\"")
        lines.append("read")
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
                try await launcher.launch(scriptURL: scriptFile)
            } catch {
                let msg = (error as? TerminalLauncherError)?.message ?? error.localizedDescription
                cont.yield(.line(L10n.terminalLaunchFailed(msg), stream: .stderr))
                cont.yield(.terminated(exitCode: 127))
                cont.finish()
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
                    try? FileManager.default.removeItem(at: dir)
                    return
                }
                if !tracker.startedEmitted {   // hasn't started yet → guard timeout
                    startupTicks += 1
                    if startupTicks >= maxStartupTicks {
                        cont.yield(.line(L10n.terminalDidNotStart, stream: .stderr))
                        cont.yield(.terminated(exitCode: 127))
                        cont.finish()
                        try? FileManager.default.removeItem(at: dir)
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
