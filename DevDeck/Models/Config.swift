import Foundation

/// Application settings stored in config.json under the `settings` key.
/// Decoding is resilient: missing keys fall back to default values.
struct Settings: Codable, Equatable {
    var vmMemoryMonitoring: Bool
    var minikubeMemoryMonitoring: Bool
    var hostMemoryMonitoring: Bool
    var globalHotkeyEnabled: Bool
    var clusterHealthMonitoring: Bool
    var autoUpdateEnabled: Bool
    /// Host side: run and announce the `gost` proxy on this machine.
    var proxyShareEnabled: Bool
    /// Client side: browse the LAN for announced proxies.
    var proxyDiscoveryEnabled: Bool
    /// Bonjour name of the proxy chosen as active — identity survives IP changes and restarts.
    var activeProxyName: String?
    /// Username for the active proxy (its password lives in the Keychain).
    var activeProxyUsername: String?
    /// Last known address of the active proxy. Bonjour dies on networks that filter multicast
    /// (any corporate VPN), while the proxy itself stays reachable over unicast TCP — this is
    /// what keeps a flagged command working there. One endpoint for the CURRENT choice, not a
    /// per-peer table.
    var activeProxyHost: String?
    var activeProxyPort: Int?
    /// Cached alongside the address: without it a remembered auth-protected proxy would resolve
    /// as open and skip the credentials requirement.
    var activeProxyAuthRequired: Bool

    init(vmMemoryMonitoring: Bool = true, minikubeMemoryMonitoring: Bool = true,
         hostMemoryMonitoring: Bool = true, globalHotkeyEnabled: Bool = false,
         clusterHealthMonitoring: Bool = true, autoUpdateEnabled: Bool = true,
         proxyShareEnabled: Bool = false, proxyDiscoveryEnabled: Bool = false,
         activeProxyName: String? = nil, activeProxyUsername: String? = nil,
         activeProxyHost: String? = nil, activeProxyPort: Int? = nil,
         activeProxyAuthRequired: Bool = false) {
        self.vmMemoryMonitoring = vmMemoryMonitoring
        self.minikubeMemoryMonitoring = minikubeMemoryMonitoring
        self.hostMemoryMonitoring = hostMemoryMonitoring
        self.globalHotkeyEnabled = globalHotkeyEnabled
        self.clusterHealthMonitoring = clusterHealthMonitoring
        self.autoUpdateEnabled = autoUpdateEnabled
        self.proxyShareEnabled = proxyShareEnabled
        self.proxyDiscoveryEnabled = proxyDiscoveryEnabled
        self.activeProxyName = activeProxyName
        self.activeProxyUsername = activeProxyUsername
        self.activeProxyHost = activeProxyHost
        self.activeProxyPort = activeProxyPort
        self.activeProxyAuthRequired = activeProxyAuthRequired
    }

    enum CodingKeys: String, CodingKey {
        case vmMemoryMonitoring, minikubeMemoryMonitoring, hostMemoryMonitoring, globalHotkeyEnabled,
             clusterHealthMonitoring, autoUpdateEnabled, proxyShareEnabled, proxyDiscoveryEnabled,
             activeProxyName, activeProxyUsername, activeProxyHost, activeProxyPort,
             activeProxyAuthRequired
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vmMemoryMonitoring = try c.decodeIfPresent(Bool.self, forKey: .vmMemoryMonitoring) ?? true
        minikubeMemoryMonitoring = try c.decodeIfPresent(Bool.self, forKey: .minikubeMemoryMonitoring) ?? true
        hostMemoryMonitoring = try c.decodeIfPresent(Bool.self, forKey: .hostMemoryMonitoring) ?? true
        globalHotkeyEnabled = try c.decodeIfPresent(Bool.self, forKey: .globalHotkeyEnabled) ?? false
        clusterHealthMonitoring = try c.decodeIfPresent(Bool.self, forKey: .clusterHealthMonitoring) ?? true
        autoUpdateEnabled = try c.decodeIfPresent(Bool.self, forKey: .autoUpdateEnabled) ?? true
        proxyShareEnabled = try c.decodeIfPresent(Bool.self, forKey: .proxyShareEnabled) ?? false
        proxyDiscoveryEnabled = try c.decodeIfPresent(Bool.self, forKey: .proxyDiscoveryEnabled) ?? false
        activeProxyName = try c.decodeIfPresent(String.self, forKey: .activeProxyName)
        activeProxyUsername = try c.decodeIfPresent(String.self, forKey: .activeProxyUsername)
        activeProxyHost = try c.decodeIfPresent(String.self, forKey: .activeProxyHost)
        activeProxyPort = try c.decodeIfPresent(Int.self, forKey: .activeProxyPort)
        activeProxyAuthRequired = try c.decodeIfPresent(Bool.self, forKey: .activeProxyAuthRequired) ?? false
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
    /// Host-side proxy sharing (the `gost` listener announced over Bonjour).
    var proxy: ProxyShare

    init(
        schemaVersion: Int = Config.currentSchemaVersion,
        commands: [Command] = [],
        chains: [Chain] = [],
        settings: Settings = Settings(),
        proxy: ProxyShare = ProxyShare()
    ) {
        self.schemaVersion = schemaVersion
        self.commands = commands
        self.chains = chains
        self.settings = settings
        self.proxy = proxy
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, commands, chains, settings, proxy
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Config.currentSchemaVersion
        commands = try c.decodeIfPresent([Command].self, forKey: .commands) ?? []
        chains = try c.decodeIfPresent([Chain].self, forKey: .chains) ?? []
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        proxy = try c.decodeIfPresent(ProxyShare.self, forKey: .proxy) ?? ProxyShare()
    }

    /// 2 — added the `proxy` block and the proxy settings/`routeThroughProxy` flag.
    /// Older files still load unchanged: every new key decodes to its default.
    static let currentSchemaVersion = 2
    static let empty = Config()
}
