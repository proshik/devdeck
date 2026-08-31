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
    static func resolve(tabs: [GhosttyTab], providers: [AgentSessionProvider]) -> [ClaudeTabEntry] {
        let ordered = tabs.sorted { ($0.windowID, $0.index) < ($1.windowID, $1.index) }
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
            for provider in providers where provider.mayOwn(tabTitle: tab.title) {
                let wanted = provider.normalize(tabTitle: tab.title)
                let candidates = sessions(for: provider, in: tab.workingDirectory)
                    .filter { !claimed.contains(ClaimKey(providerID: provider.id, sessionID: $0.id)) }
                let match = candidates.first { provider.normalize(tabTitle: $0.title) == wanted }
                    ?? candidates.first { !wanted.isEmpty && provider.normalize(tabTitle: $0.title).hasPrefix(wanted) }
                guard let match else { continue }
                claimed.insert(ClaimKey(providerID: provider.id, sessionID: match.id))
                return ClaudeTabEntry(order: position, title: tab.title,
                                      workingDirectory: tab.workingDirectory,
                                      sessionID: match.id, provider: provider.id)
            }
            return ClaudeTabEntry(order: position, title: tab.title,
                                  workingDirectory: tab.workingDirectory,
                                  sessionID: nil, provider: AgentProviderID.claude)
        }
    }
}
