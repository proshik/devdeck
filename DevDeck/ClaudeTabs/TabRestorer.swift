import Foundation

/// The line typed into a live interactive zsh.
///
/// A tab whose session did not resolve still lands in the right directory: a shell in the right
/// place is a far better failure than a lost tab.
enum RestoreCommand {
    /// `attach` rather than `--resume` for a session that is running in the background: `--resume`
    /// refuses those outright, so the restored tab would open onto an error message instead of the
    /// conversation. After a reboot nothing is in the background and every tab takes `--resume`.
    static func text(cwd: String, sessionID: String?, isBackground: Bool = false) -> String {
        guard let sessionID else { return "cd \(shellQuote(cwd))" }
        let open = isBackground
            ? "claude attach \(shellQuote(sessionID))"
            : "claude --resume \(shellQuote(sessionID))"
        return "cd \(shellQuote(cwd)) && \(open)"
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
            "-e", "input text (\"\(AppleScriptEscaper.escape(text))\" & linefeed) to focused terminal of selected tab of front window",
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

/// How a restore went: how many actions opened, how many did not.
///
/// A `Bool` cannot say "nine of ten tabs came back" — and that distinction is the whole point:
/// the caller marks a boot's restore resolved once ANYTHING opened (a retry would duplicate those
/// tabs), while a boot where NOTHING opened — the dominant case being Automation denied — must
/// stay unresolved so a retry after fixing permission is clean.
struct RestoreOutcome: Equatable {
    let succeeded: Int
    let failed: Int
}

/// Replays a restore plan into Ghostty, pacing itself so nine claude processes do not all start
/// in the same second.
struct TabRestorer {
    let runner: AppleScriptRunning
    /// Looked up by `RestoreAction.provider` (== `ClaudeTabEntry.provider`) to build the resume
    /// command — each provider owns its own agent's command line, `claude --resume`/`attach` for
    /// Claude, `opencode --session` for opencode.
    let providers: [AgentSessionProvider]
    let stepDelay: Duration

    init(runner: AppleScriptRunning = LiveAppleScriptRunner(),
         providers: [AgentSessionProvider] = [OpencodeSessionProvider(), ClaudeSessionProvider()],
         stepDelay: Duration = .milliseconds(700)) {
        self.runner = runner
        self.providers = providers
        self.stepDelay = stepDelay
    }

    /// Counts, rather than a Bool — see `RestoreOutcome`. One failed action must not stop the
    /// rest from being attempted, so every action always runs.
    @discardableResult
    func restore(_ actions: [RestoreAction]) async -> RestoreOutcome {
        var succeeded = 0
        var failed = 0
        for (offset, action) in actions.enumerated() {
            if offset > 0, stepDelay > .zero {
                try? await Task.sleep(for: stepDelay)
            }
            let args: [String]
            switch action {
            case let .inputText(cwd, sessionID, provider):
                args = RestoreScript.inputTextArgs(text: command(cwd: cwd, sessionID: sessionID, providerID: provider))
            case let .newTab(cwd, sessionID, provider):
                args = RestoreScript.newTabArgs(cwd: cwd,
                                                text: command(cwd: cwd, sessionID: sessionID, providerID: provider))
            }
            if runner.run(args) { succeeded += 1 } else { failed += 1 }
        }
        return RestoreOutcome(succeeded: succeeded, failed: failed)
    }

    /// A tab with no resolved session, or whose provider is no longer registered, still opens a
    /// shell in its directory — the feature's whole safety story, and why this never returns
    /// nothing to type at all.
    private func command(cwd: String, sessionID: String?, providerID: String) -> String {
        guard let sessionID else { return RestoreCommand.text(cwd: cwd, sessionID: nil) }
        guard let provider = providers.first(where: { $0.id == providerID }) else {
            return RestoreCommand.text(cwd: cwd, sessionID: nil)
        }
        return provider.command(resuming: sessionID, in: cwd)
    }
}
