import Foundation

/// A single dev command. Executed via `/bin/zsh -lc` (Stage 2).
/// `Codable` — stored in config.json; `Identifiable`/`Hashable` — for SwiftUI lists.
///
/// Decoding is resilient to manual edits: only `name` and `command` are required,
/// `id` is generated when absent, all other fields take default values.
/// `encode` is synthesized automatically (stable keys via `CodingKeys`).
///
/// Note: an entry added by hand without an `id` gets a NEW `id` on every
/// decode, until it is saved through the UI (at which point `id` is fixed in the file).
/// Therefore, for stable chain references, commands should be saved from the UI at least once.
struct Command: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var command: String
    var workingDirectory: String?
    var isDaemon: Bool
    var needsSudo: Bool
    var env: [String: String]
    /// GUI applications to quit before running and relaunch after (the "Free Memory" feature).
    var appsToQuit: [AppRef]
    /// Open in a dedicated Ghostty tab (for long-running processes with live output).
    var openInTerminal: Bool

    init(
        id: UUID = UUID(),
        name: String,
        command: String,
        workingDirectory: String? = nil,
        isDaemon: Bool = false,
        needsSudo: Bool = false,
        env: [String: String] = [:],
        appsToQuit: [AppRef] = [],
        openInTerminal: Bool = false
    ) {
        self.id = id
        self.name = name
        self.command = command
        self.workingDirectory = workingDirectory
        self.isDaemon = isDaemon
        self.needsSudo = needsSudo
        self.env = env
        self.appsToQuit = appsToQuit
        self.openInTerminal = openInTerminal
    }

    enum CodingKeys: String, CodingKey {
        case id, name, command, workingDirectory, isDaemon, needsSudo, env, appsToQuit, openInTerminal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decode(String.self, forKey: .name)
        command = try c.decode(String.self, forKey: .command)
        workingDirectory = try c.decodeIfPresent(String.self, forKey: .workingDirectory)
        isDaemon = try c.decodeIfPresent(Bool.self, forKey: .isDaemon) ?? false
        needsSudo = try c.decodeIfPresent(Bool.self, forKey: .needsSudo) ?? false
        env = try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:]
        appsToQuit = try c.decodeIfPresent([AppRef].self, forKey: .appsToQuit) ?? []
        openInTerminal = try c.decodeIfPresent(Bool.self, forKey: .openInTerminal) ?? false
    }
}
