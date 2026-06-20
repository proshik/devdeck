import Foundation

/// Application settings stored in config.json under the `settings` key.
/// Decoding is resilient: missing keys fall back to default values.
struct Settings: Codable, Equatable {
    var vmMemoryMonitoring: Bool
    var minikubeMemoryMonitoring: Bool
    var hostMemoryMonitoring: Bool
    var globalHotkeyEnabled: Bool
    var clusterHealthMonitoring: Bool

    init(vmMemoryMonitoring: Bool = true, minikubeMemoryMonitoring: Bool = true,
         hostMemoryMonitoring: Bool = true, globalHotkeyEnabled: Bool = false,
         clusterHealthMonitoring: Bool = true) {
        self.vmMemoryMonitoring = vmMemoryMonitoring
        self.minikubeMemoryMonitoring = minikubeMemoryMonitoring
        self.hostMemoryMonitoring = hostMemoryMonitoring
        self.globalHotkeyEnabled = globalHotkeyEnabled
        self.clusterHealthMonitoring = clusterHealthMonitoring
    }

    enum CodingKeys: String, CodingKey {
        case vmMemoryMonitoring, minikubeMemoryMonitoring, hostMemoryMonitoring, globalHotkeyEnabled, clusterHealthMonitoring
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vmMemoryMonitoring = try c.decodeIfPresent(Bool.self, forKey: .vmMemoryMonitoring) ?? true
        minikubeMemoryMonitoring = try c.decodeIfPresent(Bool.self, forKey: .minikubeMemoryMonitoring) ?? true
        hostMemoryMonitoring = try c.decodeIfPresent(Bool.self, forKey: .hostMemoryMonitoring) ?? true
        globalHotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .globalHotkeyEnabled) ?? false
        clusterHealthMonitoring = try c.decodeIfPresent(Bool.self, forKey: .clusterHealthMonitoring) ?? true
    }
}

/// Root object of config.json: the unit of (de)serialization and atomic writes.
/// Commands and chains live in a single file to avoid disk-level desync.
/// `schemaVersion` — a cheap safeguard for future migrations (outside MVP).
///
/// Decoding is resilient: any missing top-level key falls back to its default,
/// so a minimal `{ "commands": [...] }` loads correctly.
struct Config: Codable, Equatable {
    var schemaVersion: Int
    var commands: [Command]
    var chains: [Chain]
    var settings: Settings

    init(
        schemaVersion: Int = Config.currentSchemaVersion,
        commands: [Command] = [],
        chains: [Chain] = [],
        settings: Settings = Settings()
    ) {
        self.schemaVersion = schemaVersion
        self.commands = commands
        self.chains = chains
        self.settings = settings
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, commands, chains, settings
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Config.currentSchemaVersion
        commands = try c.decodeIfPresent([Command].self, forKey: .commands) ?? []
        chains = try c.decodeIfPresent([Chain].self, forKey: .chains) ?? []
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
    }

    static let currentSchemaVersion = 1
    static let empty = Config()
}
