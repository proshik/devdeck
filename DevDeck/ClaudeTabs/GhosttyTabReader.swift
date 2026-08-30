import Foundation

/// One tab of a running Ghostty, as reported by its AppleScript dictionary.
struct GhosttyTab: Equatable, Sendable {
    var windowID: String
    var index: Int
    var title: String
    var workingDirectory: String
}

/// Turns the tab-separated dump into tabs. Pure — the AppleScript itself is never run in tests.
enum GhosttyTabParser {
    /// Line format: `windowID \t index \t title \t workingDirectory`.
    ///
    /// The title is whatever Claude Code put in it and may contain tabs, so the first two fields
    /// are taken from the front and the directory from the back; everything between is the title.
    static func parse(_ output: String) -> [GhosttyTab] {
        output.split(separator: "\n").compactMap { line in
            let fields = String(line).components(separatedBy: "\t")
            guard fields.count >= 4,
                  let index = Int(fields[1].trimmingCharacters(in: .whitespaces)),
                  !fields[0].isEmpty,
                  !fields[fields.count - 1].isEmpty else { return nil }
            return GhosttyTab(windowID: fields[0],
                              index: index,
                              title: fields[2..<(fields.count - 1)].joined(separator: "\t"),
                              workingDirectory: fields[fields.count - 1])
        }
    }
}

/// Reads the open tabs — behind a protocol so the snapshot logic is tested without Ghostty.
protocol GhosttyTabReading: Sendable {
    /// nil when Ghostty is not running, or when AppleScript failed (Automation not granted yet).
    func readTabs() -> [GhosttyTab]?
}

/// Real implementation over `osascript`. `ghostty +new-window` is unsupported on macOS, so the
/// AppleScript dictionary is the only way in — and it is the same door `AppleScriptTabLauncher`
/// already uses (`Process/TerminalCommandRunner.swift:100`).
struct LiveGhosttyTabReader: GhosttyTabReading {
    func readTabs() -> [GhosttyTab]? {
        let running = !(ProcessTree.run("/usr/bin/pgrep", ["-x", "ghostty"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard running else { return nil }

        let osa = Process()
        osa.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        osa.arguments = Self.scriptArgs
        let err = Pipe()
        osa.standardError = err
        let out = Pipe()
        osa.standardOutput = out

        do {
            try osa.run()
            osa.waitUntilExit()
            guard osa.terminationStatus == 0 else {
                let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                DiagnosticLog.shared.log("GhosttyTabs: AppleScript error — \(msg)", level: .error)
                return nil
            }
        } catch {
            DiagnosticLog.shared.log("GhosttyTabs: failed to run osascript — \(error)", level: .error)
            return nil
        }

        let output = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return GhosttyTabParser.parse(output)
    }

    /// Prints one line per tab. `tab` and `linefeed` are AppleScript's own constants — the script
    /// never has to quote them, so a title full of punctuation cannot break the format.
    static let scriptArgs: [String] = [
        "-e", "tell application \"Ghostty\"",
        "-e", "set out to \"\"",
        "-e", "repeat with w in windows",
        "-e", "repeat with t in tabs of w",
        "-e", "set out to out & (id of w) & tab & (index of t) & tab & (name of t) & tab & (working directory of focused terminal of t) & linefeed",
        "-e", "end repeat",
        "-e", "end repeat",
        "-e", "return out",
        "-e", "end tell",
    ]
}
