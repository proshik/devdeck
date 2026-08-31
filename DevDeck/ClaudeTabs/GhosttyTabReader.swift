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

/// What one attempt to read Ghostty's tabs produced.
///
/// The three cases exist because two of them used to be one `nil`, and the spec asks for opposite
/// treatment: "not running" is the ordinary state of a Mac with no terminal open and stays silent
/// on the automatic path, while a failure — in practice Automation permission not granted — has to
/// reach the user, or "Capture now" is a button that does nothing and explains nothing.
enum GhosttyTabsResult: Equatable, Sendable {
    case notRunning
    /// The reason, as osascript told it. Already logged; carried here so the UI can show it too.
    case failed(String)
    case tabs([GhosttyTab])
}

/// Reads the open tabs — behind a protocol so the snapshot logic is tested without Ghostty.
protocol GhosttyTabReading: Sendable {
    func readTabs() -> GhosttyTabsResult
}

/// Real implementation over `osascript`. `ghostty +new-window` is unsupported on macOS, so the
/// AppleScript dictionary is the only way in — and it is the same door `AppleScriptTabLauncher`
/// already uses (`Process/TerminalCommandRunner.swift:100`).
struct LiveGhosttyTabReader: GhosttyTabReading {
    func readTabs() -> GhosttyTabsResult {
        let running = !(ProcessTree.run("/usr/bin/pgrep", ["-x", "ghostty"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard running else { return .notRunning }
        return runScript()
    }

    private func runScript() -> GhosttyTabsResult {
        let output = Pipe(), errors = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = Self.scriptArgs
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            DiagnosticLog.shared.log("ClaudeTabs: osascript failed to start — \(error.localizedDescription)",
                                     level: .error)
            return .failed(error.localizedDescription)
        }

        // Drain both pipes BEFORE waiting: osascript blocks writing into a full pipe buffer, and a
        // child that cannot write is a child that never exits. The tab dump grows with every tab.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            DiagnosticLog.shared.log("ClaudeTabs: reading tabs failed — \(errorText)", level: .error)
            let detail = errorText.isEmpty ? "osascript exited with \(process.terminationStatus)" : errorText
            return .failed(detail)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            return .failed("the tab list was not valid UTF-8")
        }
        return .tabs(GhosttyTabParser.parse(text))
    }

    /// Prints one line per tab.
    ///
    /// The field separator is `(ASCII character 9)`, NOT AppleScript's `tab` constant. Inside
    /// `tell application "Ghostty"` the term `tab` resolves to Ghostty's own `tab` CLASS — the one
    /// this very script iterates over — so `& tab &` concatenates the word "tab" instead of a tab
    /// character, and every line arrives with no separators at all. Verified: inside the tell block
    /// `"X" & tab & "Y"` yields `XtabY`, while `"X" & (ASCII character 9) & "Y"` yields `X\tY`.
    /// `linefeed` is not shadowed and stays as it is.
    ///
    static let scriptArgs: [String] = [
        "-e", "tell application \"Ghostty\"",
        "-e", "set sep to (ASCII character 9)",
        "-e", "set out to \"\"",
        // Each tab is read inside its own `try`, and each window's loop inside another. A tab
        // that closes WHILE this walks the list makes its reference invalid, and unguarded that
        // took down the entire enumeration — observed as "Can't get item 5 of every tab of item 1
        // of every window. Invalid index. (-1719)", after which no snapshot was taken at all.
        // Skipping the item that vanished is also the right answer on its own terms: a closed tab
        // does not belong in the snapshot.
        "-e", "repeat with w in windows",
        "-e", "try",
        "-e", "repeat with t in tabs of w",
        "-e", "try",
        "-e", "set out to out & (id of w) & sep & (index of t) & sep & (name of t) & sep & (working directory of focused terminal of t) & linefeed",
        "-e", "end try",
        "-e", "end repeat",
        "-e", "end try",
        "-e", "end repeat",
        "-e", "return out",
        "-e", "end tell",
    ]
}
