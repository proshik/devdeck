import Foundation

/// One thing to do to Ghostty when restoring.
enum RestoreAction: Equatable, Sendable {
    /// Type into the terminal Ghostty already opened for itself.
    ///
    /// `provider` is the entry's `ClaudeTabEntry.provider` — the id `TabRestorer` looks up to ask
    /// the right `AgentSessionProvider` for the resume command. `TabRestorer` ignores it when
    /// `sessionID` is `nil`, but it is carried regardless, so both cases share one uniform shape.
    case inputText(cwd: String, sessionID: String?, provider: String)
    /// Open a fresh tab configured with the directory and the command.
    case newTab(cwd: String, sessionID: String?, provider: String)
}

enum RestoreDecision: Equatable {
    case skip(reason: String)
    case restore([RestoreAction])
}

/// Decides whether this Ghostty launch is the post-reboot one, and what to open. Pure.
enum RestorePlanner {

    /// Never restore more than this in one go. If resolution ever goes wrong, the blast radius
    /// should be a screenful of tabs, not a hundred claude processes.
    static let maxTabs = 20

    /// `force` is the user pressing "Restore now", and it bypasses every guard below except the
    /// two that describe reality: without a snapshot, or with an empty one, there is nothing to
    /// open. The guards it does bypass — the feature flag and both boot checks — exist to stop the
    /// *automatic* trigger from restoring twice; someone who asked out loud is entitled to
    /// duplicates, which are visible on screen and closed with a keystroke. Left in place, the
    /// same-boot guard made the button a no-op in every situation anyone would press it: the timer
    /// stamps a snapshot with the current boot within a minute of every launch.
    static func decide(snapshot: ClaudeTabsSnapshot?,
                       enabled: Bool,
                       currentBootTime: Date,
                       restoredBootTime: Date?,
                       openTabCount: Int,
                       force: Bool = false) -> RestoreDecision {
        guard force || enabled else { return .skip(reason: "restore is off") }
        guard let snapshot else { return .skip(reason: "no snapshot") }
        guard !snapshot.tabs.isEmpty else { return .skip(reason: "snapshot is empty") }
        if !force {
            guard !BootInstant.same(snapshot.bootTime, currentBootTime) else {
                return .skip(reason: "same boot — Ghostty restarted, the machine did not")
            }
            guard !BootInstant.same(currentBootTime, restoredBootTime) else {
                return .skip(reason: "already restored in this boot")
            }
        }

        // Reuse the empty tab Ghostty opens for itself, but only when it is provably the only one.
        // If macOS restored windows of its own, typing into someone else's tab is worse than
        // leaving one blank tab behind.
        let reuseFirstTab = openTabCount == 1
        let actions = snapshot.tabs
            .sorted { $0.order < $1.order }
            .prefix(maxTabs)
            .enumerated()
            .map { offset, entry -> RestoreAction in
                offset == 0 && reuseFirstTab
                    ? .inputText(cwd: entry.workingDirectory, sessionID: entry.sessionID, provider: entry.provider)
                    : .newTab(cwd: entry.workingDirectory, sessionID: entry.sessionID, provider: entry.provider)
            }
        return .restore(actions)
    }
}
