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

    /// Through `PrivateFile`, like every other file DevDeck persists: 0600 in a 0700 directory.
    ///
    /// The snapshot is not incidental data — it lists every project directory this user works in,
    /// together with AI-generated titles describing what they were doing in each. `ps` shows every
    /// account on the Mac the full argv of every process, so this machine is not one trust domain,
    /// and the rule `PrivateFile` states is uniform for exactly that reason.
    ///
    /// `.atomic` lands a fresh inode at the default 0644, so the mode is reapplied after the write
    /// — the same order `CommandStore.save` uses for config.json, and the reason the 0700 on the
    /// directory matters: it is what keeps the brief sibling out of reach.
    func save(_ snapshot: ClaudeTabsSnapshot) throws {
        try PrivateFile.makeDirectory(at: url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        PrivateFile.restrict(url)
    }
}
