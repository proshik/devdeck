import Foundation

/// One thing to do to Ghostty when restoring.
enum RestoreAction: Equatable, Sendable {
    /// Type into the terminal Ghostty already opened for itself.
    case inputText(cwd: String, sessionID: String?)
    /// Open a fresh tab configured with the directory and the command.
    case newTab(cwd: String, sessionID: String?)
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

    static func decide(snapshot: ClaudeTabsSnapshot?,
                       enabled: Bool,
                       currentBootTime: Date,
                       restoredBootTime: Date?,
                       openTabCount: Int) -> RestoreDecision {
        guard enabled else { return .skip(reason: "restore is off") }
        guard let snapshot else { return .skip(reason: "no snapshot") }
        guard !snapshot.tabs.isEmpty else { return .skip(reason: "snapshot is empty") }
        guard snapshot.bootTime != currentBootTime else {
            return .skip(reason: "same boot — Ghostty restarted, the machine did not")
        }
        guard restoredBootTime != currentBootTime else {
            return .skip(reason: "already restored in this boot")
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
                    ? .inputText(cwd: entry.workingDirectory, sessionID: entry.sessionID)
                    : .newTab(cwd: entry.workingDirectory, sessionID: entry.sessionID)
            }
        return .restore(actions)
    }
}
