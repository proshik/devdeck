import Foundation

/// Real runner for non-sudo commands via `/bin/zsh -lc`. Stateless struct → `Sendable`.
struct ZshCommandRunner: CommandRunner {
    func start(_ command: Command) -> any RunningProcess {
        StreamingProcess(
            makeProcess: { try Self.makeProcess(command) },
            startedPID: { $0.processIdentifier },
            mapTerminal: { code, _ in .terminated(exitCode: code) }
        )
    }

    private static func makeProcess(_ command: Command) throws -> Process {
        // Pre-validate cwd: an invalid currentDirectoryURL causes an uncatchable
        // ObjC Foundation exception (crash). Check in advance → emit .terminated(127).
        if let wd = command.workingDirectory, !wd.isEmpty {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: wd, isDirectory: &isDir), isDir.boolValue else {
                throw POSIXError(.ENOENT)
            }
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // -l: login shell picks up PATH from ~/.zshrc/~/.zprofile; -c: script body as a single argument.
        process.arguments = ["-lc", command.command]
        if let wd = command.workingDirectory, !wd.isEmpty {
            process.currentDirectoryURL = URL(fileURLWithPath: wd)
        }
        // env: start with the GUI process environment (otherwise we'd wipe HOME/USER →
        // ~/.zshrc would not be read), then merge command.env on top (it wins).
        var env = ProcessInfo.processInfo.environment
        for (key, value) in command.env { env[key] = value }
        process.environment = env

        process.standardOutput = Pipe()
        process.standardError = Pipe()
        // stdin → /dev/null: a child reading stdin gets EOF instead of hanging.
        process.standardInput = FileHandle.nullDevice
        return process
    }
}
