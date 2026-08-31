import Foundation

/// One resumable agent session, as its own tool reports it.
struct AgentSession: Equatable, Sendable {
    var id: String
    var title: String
    /// Newest first is what breaks ties between two tabs with the same title, so every provider
    /// must supply something orderable — a transcript's mtime, a listing's `updated`.
    var lastActivity: Date
}

/// The provider id Claude Code is stored and matched under.
///
/// Claude has no title prefix of its own, so it is both the field's decode default — a snapshot
/// written before providers existed is a Claude snapshot — and the resolver's answer for a tab no
/// provider could claim.
enum AgentProviderID {
    static let claude = "claude"
    static let opencode = "opencode"
}

/// One coding agent, from the restore mechanism's point of view.
///
/// Only three things differ between agents; everything else — reading tabs, the snapshot, the
/// boot-time check, the planner, the restorer — is shared.
protocol AgentSessionProvider: Sendable {
    /// Stable key stored in the snapshot, e.g. "claude" / "opencode".
    var id: String { get }

    /// True for the provider that must be tried last and claims whatever nothing else did —
    /// Claude, which has no title prefix of its own to check.
    ///
    /// Encoded here rather than left to a comment on the call site: `SessionResolver.resolve`
    /// reorders providers by this flag itself, so a caller who happens to build `[Claude,
    /// Opencode]` gets the same result as `[Opencode, Claude]` — Claude's unconditional `mayOwn`
    /// can no longer swallow every tab before a prefix-bearing provider gets a look.
    var isFallback: Bool { get }

    /// Cheap pre-filter: does this tab title look like it belongs to this agent at all?
    /// Answering false must be free — it exists so we do not spawn a process per directory
    /// for a tab that plainly is not ours.
    func mayOwn(tabTitle: String) -> Bool

    func sessions(inDirectory directory: String) -> [AgentSession]

    /// The agent's own title normalization: Claude prefixes a status glyph, opencode "OC | ".
    func normalize(tabTitle: String) -> String

    /// Called once by `TabRestorer.restore`, before any `command` is built for any entry — for a
    /// provider that needs to observe something about the moment of restore once, rather than
    /// re-asking it fresh for every entry that resolves to it.
    ///
    /// Claude uses this to fetch "which sessions are running in the background" a single time
    /// instead of once per entry: the set describes the restore as a whole, not any one command,
    /// and a hidden per-call memo would bury that. The default here is a no-op for a provider
    /// (opencode) with nothing to observe up front.
    func prepareForRestore()

    /// The shell line that reopens the session.
    func command(resuming sessionID: String, in cwd: String) -> String
}

extension AgentSessionProvider {
    /// Most providers have a real prefix to check and may run in any order — only the one
    /// provider that claims everything needs to opt into running last.
    var isFallback: Bool { false }

    func prepareForRestore() {}
}

/// The one definition of "the agents this build knows about, in resolution order" — a factory,
/// not a shared array.
///
/// `ClaudeTabsModel` (capture) and `TabRestorer` (restore) each need their own default provider
/// list, and before this they were two independently written `[OpencodeSessionProvider(),
/// ClaudeSessionProvider()]` literals that happened to agree. Adding a third provider to one and
/// not the other would have made every tab of that kind silently degrade to an unresolved shell on
/// restore — no crash, no error, just sessions that quietly stopped resuming. Routing both call
/// sites through this factory makes that a one-line fix instead of a two-file one it is easy to
/// half-do.
///
/// A factory rather than a `static let` array on purpose: capture and restore must not share
/// provider *instances* (each needs its own `LiveTranscriptIndex` cache, its own
/// `prepareForRestore()` state) — only the same list of *kinds*.
enum AgentProviders {
    static func makeDefault() -> [AgentSessionProvider] {
        [OpencodeSessionProvider(), ClaudeSessionProvider()]
    }
}
