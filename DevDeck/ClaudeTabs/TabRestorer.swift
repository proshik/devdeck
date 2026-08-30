import Foundation

/// The line typed into a live interactive zsh.
///
/// A tab whose session did not resolve still lands in the right directory: a shell in the right
/// place is a far better failure than a lost tab.
enum RestoreCommand {
    static func text(cwd: String, sessionID: String?) -> String {
        guard let sessionID else { return "cd \(shellQuote(cwd))" }
        return "cd \(shellQuote(cwd)) && claude --resume \(sessionID)"
    }
}

/// The osascript arguments for each kind of action.
///
/// Note `& linefeed`: AppleScript string literals have no "\n" escape, so a backslash-n would be
/// typed literally and the command would sit on the prompt unsubmitted.
enum RestoreScript {
    static func newTabArgs(cwd: String, text: String) -> [String] {
        [
            "-e", "tell application \"Ghostty\"",
            "-e", "set cfg to new surface configuration",
            "-e", "set initial working directory of cfg to \"\(AppleScriptEscaper.escape(cwd))\"",
            "-e", "set initial input of cfg to \"\(AppleScriptEscaper.escape(text))\" & linefeed",
            // `try` swallows Ghostty's spurious -1708, which arrives even though the tab was created.
            "-e", "try",
            "-e", "new tab with configuration cfg",
            "-e", "end try",
            "-e", "end tell",
        ]
    }

    static func inputTextArgs(text: String) -> [String] {
        [
            "-e", "tell application \"Ghostty\"",
            "-e", "try",
            "-e", "input text (\"\(AppleScriptEscaper.escape(text))\" & linefeed) to focused terminal of selected tab of front window",
            "-e", "end try",
            "-e", "end tell",
        ]
    }
}

/// Runs osascript — behind a protocol so the restorer is tested without touching Ghostty.
protocol AppleScriptRunning: Sendable {
    func run(_ args: [String]) -> Bool
}

struct LiveAppleScriptRunner: AppleScriptRunning {
    func run(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = args
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            DiagnosticLog.shared.log("ClaudeTabs: osascript failed to start — \(error.localizedDescription)",
                                     level: .error)
            return false
        }
        // Drain the pipe BEFORE waiting. Only stderr is piped here and osascript's stderr is a line
        // or two, so this is not the deadlock the tab reader had — but one ordering across the
        // codebase beats two that differ by an unstated precondition.
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            DiagnosticLog.shared.log("ClaudeTabs: AppleScript error — \(message)", level: .error)
            return false
        }
        return true
    }
}

/// Replays a restore plan into Ghostty, pacing itself so nine claude processes do not all start
/// in the same second.
struct TabRestorer {
    let runner: AppleScriptRunning
    let stepDelay: Duration

    init(runner: AppleScriptRunning = LiveAppleScriptRunner(), stepDelay: Duration = .milliseconds(700)) {
        self.runner = runner
        self.stepDelay = stepDelay
    }

    /// false if any step failed — the caller surfaces it once, rather than per tab.
    @discardableResult
    func restore(_ actions: [RestoreAction]) async -> Bool {
        var allSucceeded = true
        for (offset, action) in actions.enumerated() {
            if offset > 0, stepDelay > .zero {
                try? await Task.sleep(for: stepDelay)
            }
            let args: [String]
            switch action {
            case let .inputText(cwd, sessionID):
                args = RestoreScript.inputTextArgs(text: RestoreCommand.text(cwd: cwd, sessionID: sessionID))
            case let .newTab(cwd, sessionID):
                args = RestoreScript.newTabArgs(cwd: cwd,
                                                text: RestoreCommand.text(cwd: cwd, sessionID: sessionID))
            }
            if !runner.run(args) { allSucceeded = false }
        }
        return allSucceeded
    }
}
