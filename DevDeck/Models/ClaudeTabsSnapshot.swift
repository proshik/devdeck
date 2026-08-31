import Foundation

/// One coding-agent tab as it looked at capture time.
///
/// `sessionID` is optional on purpose: a tab whose session we could not resolve is still worth
/// restoring as a shell in the right directory — better than losing it.
struct ClaudeTabEntry: Codable, Equatable, Sendable {
    var order: Int
    var title: String
    var workingDirectory: String
    var sessionID: String?
    /// Which `AgentSessionProvider` this tab resolved against — `"claude"` for an unresolved tab
    /// too, since Claude is the default provider.
    var provider: String

    private enum CodingKeys: String, CodingKey {
        case order, title, workingDirectory, sessionID, provider
    }

    init(order: Int, title: String, workingDirectory: String, sessionID: String?,
         provider: String = AgentProviderID.claude) {
        self.order = order
        self.title = title
        self.workingDirectory = workingDirectory
        self.sessionID = sessionID
        self.provider = provider
    }

    /// `provider` defaults to `"claude"` on decode, so a snapshot written before this field
    /// existed still loads as-is — the whole point of not bumping `schemaVersion` for it.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        order = try container.decode(Int.self, forKey: .order)
        title = try container.decode(String.self, forKey: .title)
        workingDirectory = try container.decode(String.self, forKey: .workingDirectory)
        sessionID = try container.decodeIfPresent(String.self, forKey: .sessionID)
        provider = try container.decodeIfPresent(String.self, forKey: .provider) ?? AgentProviderID.claude
    }
}

extension ClaudeTabEntry: Identifiable {
    var id: String { "\(order)-\(workingDirectory)" }
}

/// The tabs of one moment, stamped with the boot they belonged to.
///
/// `bootTime` is what tells a reboot ("restore these") from an ordinary Ghostty restart
/// ("leave them alone").
struct ClaudeTabsSnapshot: Codable, Equatable, Sendable {
    var bootTime: Date
    var capturedAt: Date
    var tabs: [ClaudeTabEntry]
}
