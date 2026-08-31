import Foundation

/// Matches open Ghostty tabs to agent sessions by their titles. Pure by design: this is the one
/// piece of guesswork in the feature, so it has to be exhaustively testable.
enum SessionResolver {

    /// A claimed session, namespaced by provider: two providers are free to hand out the same raw
    /// id without one's claim reading as the other's.
    private struct ClaimKey: Hashable {
        var providerID: String
        var sessionID: String
    }

    /// Tabs in display order, each carrying the session we could resolve for it.
    ///
    /// For every tab, providers are tried in the order given; the first one whose `mayOwn` answers
    /// true AND that finds a match wins. A session already claimed by an earlier tab — same
    /// provider, same id — is removed from later candidates: that is what keeps two tabs with the
    /// same title in the same directory from collapsing onto one session.
    ///
    /// When several candidates share a normalized title, the winner is simply the first the
    /// provider returned — `resolve` never reads `lastActivity` itself. "Most recently active wins
    /// a tie" depends entirely on each provider handing over newest-first entries.
    ///
    /// A tab that no provider could resolve to a session still records which agent it belongs to:
    /// the last non-fallback provider whose `mayOwn` claimed it, or Claude — the fallback — only
    /// when none did. That is what keeps an opencode-titled tab that merely failed to match a
    /// session from being mislabelled Claude in the Agent column.
    static func resolve(tabs: [GhosttyTab], providers: [AgentSessionProvider]) -> [ClaudeTabEntry] {
        let ordered = tabs.sorted { ($0.windowID, $0.index) < ($1.windowID, $1.index) }
        // Fallbacks last, regardless of the order the caller passed in. Built by filtering rather
        // than sorting: the standard library does NOT document `sorted` as stable, so relying on it
        // to keep two non-fallback (or two fallback) providers in their given order would be
        // unfounded — filtering into two passes preserves each group's relative order by
        // construction, no stability guarantee needed.
        let providers = providers.filter { !$0.isFallback } + providers.filter(\.isFallback)
        var claimed: Set<ClaimKey> = []

        // One `sessions(inDirectory:)` call per (provider, directory) for the whole resolve, not
        // per tab: two tabs open in the same directory must not double the transcript read or the
        // subprocess a listing-backed provider spawns.
        var sessionsCache: [String: [String: [AgentSession]]] = [:]
        func sessions(for provider: AgentSessionProvider, in directory: String) -> [AgentSession] {
            if let cached = sessionsCache[provider.id]?[directory] { return cached }
            let fetched = provider.sessions(inDirectory: directory)
            sessionsCache[provider.id, default: [:]][directory] = fetched
            return fetched
        }

        return ordered.enumerated().map { position, tab in
            // The last non-fallback provider whose `mayOwn` claimed this tab — recorded even when
            // it found no match, so an unresolved tab still names its real agent instead of
            // silently defaulting to Claude. Claude itself is excluded here: its `mayOwn` is an
            // unconditional `true`, not a real claim, and it is what the final fallback already is.
            var lastOwner: String?
            for provider in providers where provider.mayOwn(tabTitle: tab.title) {
                let wanted = provider.normalize(tabTitle: tab.title)
                let candidates = sessions(for: provider, in: tab.workingDirectory)
                    .filter { !claimed.contains(ClaimKey(providerID: provider.id, sessionID: $0.id)) }
                let match = candidates.first { provider.normalize(tabTitle: $0.title) == wanted }
                    ?? candidates.first { !wanted.isEmpty && provider.normalize(tabTitle: $0.title).hasPrefix(wanted) }
                guard let match else {
                    if !provider.isFallback { lastOwner = provider.id }
                    continue
                }
                claimed.insert(ClaimKey(providerID: provider.id, sessionID: match.id))
                return ClaudeTabEntry(order: position, title: tab.title,
                                      workingDirectory: tab.workingDirectory,
                                      sessionID: match.id, provider: provider.id)
            }
            return ClaudeTabEntry(order: position, title: tab.title,
                                  workingDirectory: tab.workingDirectory,
                                  sessionID: nil, provider: lastOwner ?? AgentProviderID.claude)
        }
    }
}
