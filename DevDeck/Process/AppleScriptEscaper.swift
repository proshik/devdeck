import Foundation

/// Escapes a string into an AppleScript string literal for `do shell script "..."`.
/// Pure function — round-trip unit tests without osascript.
///
/// We escape backslash FIRST (otherwise we would double-escape already-added ones)
/// and then double quotes.
enum AppleScriptEscaper {
    static func escape(_ string: String) -> String {
        string
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}
