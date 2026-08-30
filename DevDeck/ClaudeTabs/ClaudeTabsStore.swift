import Foundation

/// Reads and writes `~/Library/Application Support/DevDeck/claude-tabs.json`.
///
/// A separate file from `config.json` deliberately: this is machine state rewritten every minute,
/// and mixing it into the hand-editable config would make both worse.
struct ClaudeTabsStore {
    let url: URL

    init(url: URL = PrivateFile.applicationSupportDirectory
            .appendingPathComponent("claude-tabs.json")) {
        self.url = url
    }

    /// Missing or malformed reads as "no snapshot" — never throws. The file is disposable.
    func load() -> ClaudeTabsSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClaudeTabsSnapshot.self, from: data)
    }

    func save(_ snapshot: ClaudeTabsSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
