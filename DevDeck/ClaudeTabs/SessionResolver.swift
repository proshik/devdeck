import Foundation

/// Matches open Ghostty tabs to Claude Code sessions by their titles. Pure by design: this is the
/// one piece of guesswork in the feature, so it has to be exhaustively testable.
enum SessionResolver {

    /// Claude Code prefixes the tab title with a status glyph ("✳ ", "◐ "). Strip any leading run
    /// of non-alphanumerics so the title matches the `aiTitle` recorded in the transcript.
    static func normalize(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tabs in display order, each carrying the session we could resolve for it.
    ///
    /// A session already claimed by an earlier tab is removed from the candidates: that is what
    /// keeps two tabs with the same title in the same directory from collapsing onto one session.
    ///
    /// When several candidates share a normalized title, the winner is simply the first in the
    /// caller-supplied array — `resolve` never reads `modifiedAt`. "Most recently modified wins
    /// a tie" depends entirely on the caller handing over newest-first entries.
    static func resolve(tabs: [GhosttyTab],
                        titlesByDirectory: [String: [TranscriptTitle]]) -> [ClaudeTabEntry] {
        let ordered = tabs.sorted { ($0.windowID, $0.index) < ($1.windowID, $1.index) }
        var claimed: Set<String> = []
        return ordered.enumerated().map { position, tab in
            let wanted = normalize(tab.title)
            let candidates = (titlesByDirectory[tab.workingDirectory] ?? [])
                .filter { !claimed.contains($0.sessionID) }
            let match = candidates.first { normalize($0.aiTitle) == wanted }
                ?? candidates.first { !wanted.isEmpty && normalize($0.aiTitle).hasPrefix(wanted) }
            if let match { claimed.insert(match.sessionID) }
            return ClaudeTabEntry(order: position,
                                  title: tab.title,
                                  workingDirectory: tab.workingDirectory,
                                  sessionID: match?.sessionID)
        }
    }
}
