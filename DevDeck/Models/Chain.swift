import Foundation

/// Sequential chain of commands. The next command starts after the previous one succeeds;
/// with `stopOnError` execution halts at the failed step (Stage 2).
///
/// Decoding is resilient to manual edits: only `name` is required,
/// `id` is generated when absent, `commandIDs` → [], `stopOnError` → true.
struct Chain: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var commandIDs: [UUID]
    var stopOnError: Bool
    /// Run the entire chain as a single script in one Ghostty tab (live output view).
    var openInTerminal: Bool

    init(
        id: UUID = UUID(),
        name: String,
        commandIDs: [UUID] = [],
        stopOnError: Bool = true,
        openInTerminal: Bool = false
    ) {
        self.id = id
        self.name = name
        self.commandIDs = commandIDs
        self.stopOnError = stopOnError
        self.openInTerminal = openInTerminal
    }

    enum CodingKeys: String, CodingKey {
        case id, name, commandIDs, stopOnError, openInTerminal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        commandIDs = try c.decodeIfPresent([UUID].self, forKey: .commandIDs) ?? []
        stopOnError = try c.decodeIfPresent(Bool.self, forKey: .stopOnError) ?? true
        openInTerminal = try c.decodeIfPresent(Bool.self, forKey: .openInTerminal) ?? false
    }
}
