import Foundation

/// One Claude Code tab as it looked at capture time.
///
/// `sessionID` is optional on purpose: a tab whose session we could not resolve is still worth
/// restoring as a shell in the right directory — better than losing it.
struct ClaudeTabEntry: Codable, Equatable {
    var order: Int
    var title: String
    var workingDirectory: String
    var sessionID: String?
}

extension ClaudeTabEntry: Identifiable {
    var id: String { "\(order)-\(workingDirectory)" }
}

/// The tabs of one moment, stamped with the boot they belonged to.
///
/// `bootTime` is what tells a reboot ("restore these") from an ordinary Ghostty restart
/// ("leave them alone").
struct ClaudeTabsSnapshot: Codable, Equatable {
    var bootTime: Date
    var capturedAt: Date
    var tabs: [ClaudeTabEntry]
}
