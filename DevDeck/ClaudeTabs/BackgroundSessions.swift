import Foundation

/// Which Claude sessions are currently running as BACKGROUND sessions.
///
/// A background session refuses to be resumed — `claude --resume <id>` answers "is running as a
/// background session… run `claude attach <id>`" — so restoring one with `--resume` produces a tab
/// that opens onto an error instead of the conversation.
///
/// This matters less than it sounds: after a reboot no background session exists, because its host
/// process dies with the machine and its socket lives in `/tmp`, which macOS clears at boot. So the
/// feature's main path is unaffected, and this covers the same-boot cases — "Restore now", or a
/// Ghostty relaunch — where the session really is still alive somewhere.
protocol BackgroundSessionListing: Sendable {
    /// Full session ids of the sessions currently running in the background.
    ///
    /// Empty on any failure. That degrades to `--resume`, which is both the right answer whenever
    /// we cannot tell and the only correct answer after a reboot.
    func backgroundSessionIDs() -> Set<String>
}

/// Parsing of `claude agents --json`, kept pure and deliberately lenient: this is another tool's
/// output format, and a change there must cost us `--resume` rather than a crash.
enum BackgroundSessions {
    static func parse(_ data: Data) -> Set<String> {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return Set(entries.compactMap { entry in
            guard entry["kind"] as? String == "background",
                  let id = entry["sessionId"] as? String,
                  !id.isEmpty else { return nil }
            return id
        })
    }
}

struct LiveBackgroundSessions: BackgroundSessionListing {
    func backgroundSessionIDs() -> Set<String> {
        // Through a login shell, like everything else this app runs: `claude` lives in
        // ~/.local/bin, which is not on a GUI application's PATH.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "claude agents --json"]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            DiagnosticLog.shared.log("ClaudeTabs: could not list background sessions — "
                + error.localizedDescription)
            return []
        }
        // Drain before waiting, as everywhere else in this feature: a child that cannot write is a
        // child that never exits.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            DiagnosticLog.shared.log("ClaudeTabs: `claude agents --json` exited "
                + "\(process.terminationStatus) — assuming no background sessions")
            return []
        }
        return BackgroundSessions.parse(data)
    }
}
