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

    /// The shell line that reopens the session.
    func command(resuming sessionID: String, in cwd: String) -> String
}

extension AgentSessionProvider {
    /// Most providers have a real prefix to check and may run in any order — only the one
    /// provider that claims everything needs to opt into running last.
    var isFallback: Bool { false }
}
