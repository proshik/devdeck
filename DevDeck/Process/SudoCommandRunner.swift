import Foundation

/// Router: `ProcessManager` sees ONE `CommandRunner`; tests inject ONE fake.
struct RoutingCommandRunner: CommandRunner {
    let zsh: any CommandRunner
    let sudo: any CommandRunner
    let terminal: any CommandRunner

    init(
        zsh: any CommandRunner = ZshCommandRunner(),
        sudo: any CommandRunner = SudoCommandRunner(),
        terminal: any CommandRunner = GhosttyCommandRunner()
    ) {
        self.zsh = zsh
        self.sudo = sudo
        self.terminal = terminal
    }

    func start(_ command: Command) -> any RunningProcess {
        if command.openInTerminal { return terminal.start(command) }   // priority: terminal
        return command.needsSudo ? sudo.start(command) : zsh.start(command)
    }
}

/// The sudo path, two modes:
///
/// 1. **Touch ID** (`pam_tid.so` enabled in `/etc/pam.d/sudo_local`): direct
///    `/usr/bin/sudo /bin/sh -c …` — system Touch ID dialog instead of a password,
///    live output stream (unlike the osascript path). Authorization failure
///    (fingerprint cancelled / clamshell without sensor) is detected via a sudo
///    signature in stderr → automatic fallback to the password dialog (mode 2).
/// 2. **osascript** `with administrator privileges` — native password dialog.
///    Limitations: no live stream (output arrives as one chunk at the end), no pid
///    for the privileged child (stop is best-effort), runs `sh` internally, not zsh.
struct SudoCommandRunner: CommandRunner {
    func start(_ command: Command) -> any RunningProcess {
        guard TouchIDSudo.isEnabled() else { return Self.startViaOsascript(command) }
        return FallbackProcess(
            primary: { Self.startViaSudo(command) },
            fallback: { Self.startViaOsascript(command) },
            shouldFallback: Self.isAuthFailure
        )
    }

    /// Direct sudo: pam_tid will raise the Touch ID dialog; normal process → stream/pid.
    /// stop() is best-effort: the child runs as root, the kernel will not deliver our SIGTERM.
    static func startViaSudo(_ command: Command) -> any RunningProcess {
        let inner = buildInnerShell(command)
        return StreamingProcess(
            makeProcess: {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
                process.arguments = ["/bin/sh", "-c", inner]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                process.standardInput = FileHandle.nullDevice   // no tty → sudo won't hang waiting for a password
                return process
            },
            startedPID: { $0.processIdentifier },
            mapTerminal: { code, _ in .terminated(exitCode: code) }
        )
    }

    /// sudo authorization failure: the command produced no output, exit code is non-zero,
    /// and the stderr tail contains the "sudo could not ask for a password" signature (no tty).
    static func isAuthFailure(exitCode: Int32, sawStdout: Bool, stderrTail: [String]) -> Bool {
        guard exitCode != 0, !sawStdout else { return false }
        return stderrTail.contains { line in
            line.contains("a password is required") || line.contains("a terminal is required")
        }
    }

    static func startViaOsascript(_ command: Command) -> any RunningProcess {
        let inner = buildInnerShell(command)
        let script = "do shell script \"\(AppleScriptEscaper.escape(inner))\" with administrator privileges"
        return StreamingProcess(
            makeProcess: {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
                process.arguments = ["-e", script]
                process.standardOutput = Pipe()
                process.standardError = Pipe()
                process.standardInput = FileHandle.nullDevice
                return process
            },
            startedPID: { _ in nil },   // we do not control the privileged child
            mapTerminal: { code, cancelled in cancelled ? .cancelled : .terminated(exitCode: code) },
            // Password dialog cancelled = AppleScript error -128 → osascript prints to stderr.
            cancelMarkers: ["User canceled", "(-128)"]
        )
    }

    /// `cd` + `export` prefix: `do shell script` runs in `sh` without our env/cwd.
    static func buildInnerShell(_ command: Command) -> String {
        var parts: [String] = []
        if let wd = command.workingDirectory, !wd.isEmpty {
            parts.append("cd \(shQuote(wd))")
        }
        for (key, value) in command.env.sorted(by: { $0.key < $1.key }) {
            parts.append("export \(key)=\(shQuote(value))")
        }
        parts.append(command.command)
        return parts.joined(separator: "; ")
    }

    static func shQuote(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
