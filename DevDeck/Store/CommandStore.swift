import Foundation
import Observation

/// Source of truth for commands and chains. `@Observable` + `@MainActor`:
/// the popover and the main window read one consistent state and update in sync.
///
/// Invariants:
/// - `config` always holds the LAST VALID configuration; a broken file does not overwrite it.
/// - `error` is non-nil when the file on disk can't be read/parsed → the UI shows a banner;
///   it is cleared by the next successful `reload`.
/// - Suppressing the reaction to our own write relies on an Equatable comparison
///   (our `save` writes exactly the in-memory `config` → the echo decodes to an equal value → no-op),
///   so correctness does not depend on timing.
@MainActor
@Observable
final class CommandStore {
    private(set) var config: Config = .empty
    private(set) var error: String?

    @ObservationIgnored private let configURL: URL
    @ObservationIgnored private let defaultConfigData: Data?
    @ObservationIgnored private var watcher: FileWatcher?

    init(configURL: URL = CommandStore.defaultConfigURL, defaultConfigData: Data? = nil) {
        self.configURL = configURL
        self.defaultConfigData = defaultConfigData
    }

    /// Commands by id — for running chains (`ProcessManager.run(chain, commands:)`).
    /// On a duplicate id (manual edit) the first command wins — don't crash the app.
    var commandsByID: [UUID: Command] {
        Dictionary(config.commands.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// `~/Library/Application Support/DevDeck/config.json`.
    nonisolated static var defaultConfigURL: URL {
        PrivateFile.applicationSupportDirectory.appendingPathComponent("config.json")
    }

    /// Full start: first launch (copy the default) → load → watch. Idempotent w.r.t. the file.
    ///
    /// The permissions pass runs on every launch rather than only on creation, because installs
    /// made before it shipped have a 0755 directory and a 0644 config — and config.json is a
    /// complete description of what this user runs and where, readable by every other account on
    /// the Mac. A save would fix it too, but only for users who happen to save.
    func start() {
        installDefaultConfigIfNeeded()
        try? ensureDirectoryExists()
        PrivateFile.restrict(configURL)
        reload()
        startWatching()
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }

    /// Re-read the file. Entry point for the watcher and a manual "refresh".
    /// Returns `true` if the state actually changed (to suppress a redundant publish).
    @discardableResult
    func reload() -> Bool {
        do {
            let data = try Data(contentsOf: configURL)
            let decoded = try ConfigCodec.decode(data)
            error = nil
            guard decoded != config else { return false }
            config = decoded
            DiagnosticLog.shared.log("Config loaded: \(config.commands.count) commands, \(config.chains.count) chains")
            return true
        } catch {
            let described = Self.describe(error)
            if self.error != described {   // don't spam while the file is flapping/half-written
                DiagnosticLog.shared.log("Config read error: \(described)", level: .error)
            }
            self.error = described
            return false
        }
    }

    /// Atomically save the config (temp + rename) and update the in-memory state.
    ///
    /// `.atomic` is kept — a torn config file is a worse failure than a brief permissions window,
    /// and unlike `proxy.env` this file holds no password. The rename lands a fresh inode at the
    /// default 0644, so the mode is reapplied right after every write.
    func save(_ newConfig: Config) throws {
        let data = try ConfigCodec.encode(newConfig)
        try ensureDirectoryExists()
        try data.write(to: configURL, options: .atomic)
        PrivateFile.restrict(configURL)
        config = newConfig
        error = nil
    }

    // MARK: mutations from the UI (Stage 4)

    /// Add or update a command (by id) and save atomically.
    func upsert(_ command: Command) {
        var updated = config
        if let index = updated.commands.firstIndex(where: { $0.id == command.id }) {
            updated.commands[index] = command
        } else {
            updated.commands.append(command)
        }
        persist(updated)
    }

    /// Delete a command and remove its id from all chains.
    func delete(commandID: UUID) {
        var updated = config
        updated.commands.removeAll { $0.id == commandID }
        for index in updated.chains.indices {
            updated.chains[index].commandIDs.removeAll { $0 == commandID }
        }
        persist(updated)
    }

    /// Add or update a chain (by id) and save atomically.
    func upsert(_ chain: Chain) {
        var updated = config
        if let index = updated.chains.firstIndex(where: { $0.id == chain.id }) {
            updated.chains[index] = chain
        } else {
            updated.chains.append(chain)
        }
        persist(updated)
    }

    func delete(chainID: UUID) {
        var updated = config
        updated.chains.removeAll { $0.id == chainID }
        persist(updated)
    }

    /// Reorder a subset of commands (daemons or regular) by sidebar drag-and-drop.
    /// Indices are in the coordinates of the section's filtered list; positions of the OTHER
    /// kind of command in the combined array don't change (stable for manual JSON edits).
    func moveCommands(_ source: IndexSet, to destination: Int, daemons: Bool) {
        var subset = config.commands.filter { $0.isDaemon == daemons }
        subset.move(fromOffsets: source, toOffset: destination)
        var iterator = subset.makeIterator()
        var updated = config
        updated.commands = config.commands.map { $0.isDaemon == daemons ? iterator.next()! : $0 }
        guard updated != config else { return }
        persist(updated)
    }

    /// Reorder chains by sidebar drag-and-drop.
    func moveChains(_ source: IndexSet, to destination: Int) {
        var updated = config
        updated.chains.move(fromOffsets: source, toOffset: destination)
        guard updated != config else { return }
        persist(updated)
    }

    /// Toggle the per-daemon watchdog flag (the shield button in the popover) and save atomically.
    func setWatchdog(_ enabled: Bool, forCommand id: UUID) {
        guard let index = config.commands.firstIndex(where: { $0.id == id }),
              config.commands[index].watchdogEnabled != enabled else { return }
        var updated = config
        updated.commands[index].watchdogEnabled = enabled
        persist(updated)
    }

    /// Toggle the VM memory-monitoring flag and save atomically.
    func setVMMonitoring(_ on: Bool) {
        guard config.settings.vmMemoryMonitoring != on else { return }
        var updated = config
        updated.settings.vmMemoryMonitoring = on
        persist(updated)
    }

    func setMinikubeMonitoring(_ on: Bool) {
        guard config.settings.minikubeMemoryMonitoring != on else { return }
        var updated = config
        updated.settings.minikubeMemoryMonitoring = on
        persist(updated)
    }

    func setHostMonitoring(_ on: Bool) {
        guard config.settings.hostMemoryMonitoring != on else { return }
        var updated = config
        updated.settings.hostMemoryMonitoring = on
        persist(updated)
    }

    func setGlobalHotkey(_ on: Bool) {
        guard config.settings.globalHotkeyEnabled != on else { return }
        var updated = config
        updated.settings.globalHotkeyEnabled = on
        persist(updated)
    }

    func setAutoUpdate(_ on: Bool) {
        guard config.settings.autoUpdateEnabled != on else { return }
        var updated = config
        updated.settings.autoUpdateEnabled = on
        persist(updated)
    }

    func setClusterHealth(_ on: Bool) {
        guard config.settings.clusterHealthMonitoring != on else { return }
        var updated = config
        updated.settings.clusterHealthMonitoring = on
        persist(updated)
    }

    // MARK: proxy manager

    /// Host side: share this machine's proxy on the LAN.
    func setProxyShareEnabled(_ on: Bool) {
        guard config.settings.proxyShareEnabled != on else { return }
        var updated = config
        updated.settings.proxyShareEnabled = on
        persist(updated)
    }

    /// Client side: browse the LAN for announced proxies.
    func setProxyDiscoveryEnabled(_ on: Bool) {
        guard config.settings.proxyDiscoveryEnabled != on else { return }
        var updated = config
        updated.settings.proxyDiscoveryEnabled = on
        persist(updated)
    }

    /// Pick the active proxy by its Bonjour name (nil — none). The username is persisted next to it;
    /// the password stays in the Keychain.
    func setActiveProxy(name: String?, username: String? = nil) {
        guard config.settings.activeProxyName != name
                || config.settings.activeProxyUsername != username else { return }
        var updated = config
        updated.settings.activeProxyName = name
        updated.settings.activeProxyUsername = username
        if name == nil {
            // The endpoint belongs to the choice — keeping it would let a stale address
            // resurrect a proxy the user deselected.
            updated.settings.activeProxyHost = nil
            updated.settings.activeProxyPort = nil
            updated.settings.activeProxyAuthRequired = false
            updated.settings.activeProxyLANPrefix = nil
        }
        persist(updated)
    }

    /// Remember where the active proxy was last reachable, so it survives Bonjour going quiet.
    /// `lanPrefix` is the /24 of THIS machine's LAN at that moment: the address is only usable back
    /// on the same network, so the scope travels with it.
    /// Guarded: this is called on every browse update, and an unguarded write would hit the disk
    /// several times a second.
    func rememberActiveProxyEndpoint(host: String, port: Int, authRequired: Bool, lanPrefix: String?) {
        guard config.settings.activeProxyHost != host
                || config.settings.activeProxyPort != port
                || config.settings.activeProxyAuthRequired != authRequired
                || config.settings.activeProxyLANPrefix != lanPrefix else { return }
        var updated = config
        updated.settings.activeProxyHost = host
        updated.settings.activeProxyPort = port
        updated.settings.activeProxyAuthRequired = authRequired
        updated.settings.activeProxyLANPrefix = lanPrefix
        persist(updated)
    }

    /// Save the host-side share config (port / auth / username / service name).
    func upsertProxyShare(_ share: ProxyShare) {
        guard config.proxy != share else { return }
        var updated = config
        updated.proxy = share
        persist(updated)
    }

    /// Save; a write failure goes into `error` (the UI shows a banner) instead of throwing out.
    private func persist(_ newConfig: Config) {
        do {
            try save(newConfig)
            DiagnosticLog.shared.log("Config saved from UI: \(newConfig.commands.count) commands, \(newConfig.chains.count) chains")
        } catch {
            self.error = Self.describe(error)
            DiagnosticLog.shared.log("Config save error: \(self.error ?? "")", level: .error)
        }
    }

    // MARK: private

    private func installDefaultConfigIfNeeded() {
        guard !FileManager.default.fileExists(atPath: configURL.path) else { return }
        try? ensureDirectoryExists()
        // No bundled default → write an empty valid config so the file always exists.
        // encode(.empty) effectively never fails; in the impossible failure case we just skip creating it.
        guard let data = defaultConfigData ?? (try? ConfigCodec.encode(.empty)) else { return }
        try? data.write(to: configURL, options: .atomic)
        PrivateFile.restrict(configURL)
        DiagnosticLog.shared.log("First launch: wrote the starter config (\(defaultConfigData != nil ? "bundled examples" : "empty"))")
    }

    private func ensureDirectoryExists() throws {
        try PrivateFile.makeDirectory(at: configURL.deletingLastPathComponent())
    }

    private func startWatching() {
        let watcher = FileWatcher(fileURL: configURL) { [weak self] in
            self?.reload()
        }
        self.watcher = watcher
        watcher.start()
    }

    private static func describe(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else {
            return (error as NSError).localizedDescription
        }
        switch decoding {
        case .dataCorrupted(let ctx):
            return L10n.brokenJSON(ctx.debugDescription)
        case .keyNotFound(let key, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            let at = path.isEmpty ? "" : " (\(path))"
            return L10n.missingField(key.stringValue, at)
        case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx):
            let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
            let location = path.isEmpty ? L10n.atFileRoot : L10n.atPath(path)
            return L10n.wrongType(location, ctx.debugDescription)
        @unknown default:
            return decoding.localizedDescription
        }
    }
}
