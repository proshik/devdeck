import XCTest
@testable import DevDeck

/// Stage 9 end-to-end scenarios over real files in a temporary directory: an upgrade from the last
/// release before the modular rework, and a damaged config that must not lose the user's data.
@MainActor
final class Stage9EndToEndTests: XCTestCase {
    private var directory: URL!
    private var configURL: URL!
    private var store: CommandStore?

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("DevDeckStage9-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        configURL = directory.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        store?.stop(); store = nil
        try? FileManager.default.removeItem(at: directory)
    }

    /// Written by hand after the v0.22.1 schema (`git show v0.22.1:DevDeck/Models/*.swift`): every
    /// key that release knew, with non-default values, and nothing it did not know.
    static let v0_22_1Config = """
    {
      "chains" : [
        { "commandIDs" : ["11111111-1111-1111-1111-111111111111", "22222222-2222-2222-2222-222222222222"],
          "id" : "33333333-3333-3333-3333-333333333333", "name" : "Up", "openInTerminal" : true, "stopOnError" : false }
      ],
      "commands" : [
        { "appsToQuit" : [ { "bundleID" : "com.google.Chrome", "name" : "Google Chrome" } ],
          "command" : "colima start --cpu 6", "env" : { "DOCKER_HOST" : "unix:///tmp/docker.sock" },
          "id" : "11111111-1111-1111-1111-111111111111", "isDaemon" : false, "keepTerminalOpen" : true,
          "name" : "colima start", "needsSudo" : false, "openInTerminal" : true, "port" : null,
          "promptForDirectory" : true, "routeThroughProxy" : true, "watchdogEnabled" : false,
          "workingDirectory" : "~/work" },
        { "appsToQuit" : [], "command" : "kubectl port-forward svc/api 8080:80", "env" : {},
          "id" : "22222222-2222-2222-2222-222222222222", "isDaemon" : true, "keepTerminalOpen" : false,
          "name" : "api forward", "needsSudo" : false, "openInTerminal" : false, "port" : 8080,
          "promptForDirectory" : false, "routeThroughProxy" : false, "watchdogEnabled" : true,
          "workingDirectory" : null },
        { "appsToQuit" : [], "command" : "ssh -N -D 1081 vds", "env" : {},
          "id" : "44444444-4444-4444-4444-444444444444", "isDaemon" : true, "keepTerminalOpen" : false,
          "name" : "vds tunnel", "needsSudo" : false, "openInTerminal" : false, "port" : 1081,
          "promptForDirectory" : false, "routeThroughProxy" : false, "watchdogEnabled" : true,
          "workingDirectory" : null }
      ],
      "proxy" : { "authEnabled" : true, "engine" : "gost", "port" : 18080, "serviceName" : "Work Mac", "username" : "me" },
      "remoteProxies" : [
        { "id" : "55555555-5555-5555-5555-555555555555", "localPort" : 18090, "name" : "VDS",
          "socksPort" : 1081, "tunnelCommandID" : "44444444-4444-4444-4444-444444444444" }
      ],
      "schemaVersion" : 2,
      "settings" : {
        "activeProxyAuthRequired" : true, "activeProxyHost" : "192.168.1.20", "activeProxyLANPrefix" : "192.168.1",
        "activeProxyName" : "Home Mac", "activeProxyPort" : 18080, "activeProxyUsername" : "home",
        "activeRemoteProxyID" : "55555555-5555-5555-5555-555555555555", "autoUpdateEnabled" : false,
        "batteryMonitoring" : false, "claudeTabsCaptureSeconds" : 120, "claudeTabsRestore" : true,
        "clusterHealthMonitoring" : false, "containerEngine" : "dockerDesktop", "globalHotkeyEnabled" : false,
        "hostMemoryMonitoring" : false, "minikubeMemoryMonitoring" : false, "proxyDiscoveryEnabled" : true,
        "proxyShareEnabled" : true, "vmMemoryMonitoring" : false
      }
    }
    """

    private func jsonObject(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Every value of `old` is present, unchanged, in `new` (new keys may be added beside it).
    private func assertContains(_ new: Any, _ old: Any, path: String = "$", file: StaticString = #filePath, line: UInt = #line) {
        switch (old, new) {
        case let (old as [String: Any], new as [String: Any]):
            for (key, value) in old {
                if value is NSNull { continue }   // nil optionals are omitted by the encoder
                guard let newValue = new[key] else { XCTFail("\(path).\(key) lost", file: file, line: line); continue }
                assertContains(newValue, value, path: "\(path).\(key)", file: file, line: line)
            }
        case let (old as [Any], new as [Any]):
            XCTAssertEqual(old.count, new.count, "\(path) count", file: file, line: line)
            for (index, pair) in zip(old, new).enumerated() {
                assertContains(pair.1, pair.0, path: "\(path)[\(index)]", file: file, line: line)
            }
        default:
            XCTAssertTrue((new as AnyObject).isEqual(old), "\(path): \(new) ≠ \(old)", file: file, line: line)
        }
    }

    func testLastReleaseConfigUpgradesWithoutLoss() throws {
        try Data(Self.v0_22_1Config.utf8).write(to: configURL)
        let store = CommandStore(configURL: configURL); self.store = store
        store.start()
        XCTAssertNil(store.error)
        let config = store.config
        XCTAssertEqual(config.commands.map(\.name), ["colima start", "api forward", "vds tunnel"])
        XCTAssertEqual(config.commands[0].appsToQuit, [AppRef(bundleID: "com.google.Chrome", name: "Google Chrome")])
        XCTAssertEqual(config.commands[0].env, ["DOCKER_HOST": "unix:///tmp/docker.sock"])
        XCTAssertTrue(config.commands[0].promptForDirectory && config.commands[0].keepTerminalOpen)
        XCTAssertEqual(config.commands[1].port, 8080)
        XCTAssertEqual(config.chains.first?.stopOnError, false)
        XCTAssertEqual(config.proxy.engine, .gost)
        XCTAssertEqual(config.remoteProxies.first?.tunnelCommandID, UUID(uuidString: "44444444-4444-4444-4444-444444444444"))
        XCTAssertEqual(config.settings.containerEngine, .dockerDesktop)
        XCTAssertEqual(config.settings.claudeTabsCaptureSeconds, 120)
        // Features the release did not have start off, and nothing becomes reachable from outside.
        XCTAssertFalse(config.settings.clipboard.enabled)
        XCTAssertFalse(config.settings.displays.keyboardEnabled)
        XCTAssertFalse(config.settings.automationEnabled)
        XCTAssertFalse(config.commands.contains(where: \.allowAutomation))
        XCTAssertEqual(config.panel, .standard)

        // Reading alone does not rewrite the user's file.
        XCTAssertEqual(try Data(contentsOf: configURL), Data(Self.v0_22_1Config.utf8))

        // The first save from the UI keeps every value the old release wrote.
        store.setGlobalHotkey(true)
        let saved = try Data(contentsOf: configURL)
        var expected = try jsonObject(Data(Self.v0_22_1Config.utf8))
        var settings = try XCTUnwrap(expected["settings"] as? [String: Any])
        settings["globalHotkeyEnabled"] = true
        expected["settings"] = settings
        assertContains(try jsonObject(saved), expected)
        XCTAssertEqual(try ConfigCodec.decode(saved), store.config)
    }

    func testUIWriteOverADamagedConfigKeepsTheUsersFile() throws {
        try ConfigCodec.encode(Config(commands: [Command(name: "valid", command: "true")])).write(to: configURL)
        let store = CommandStore(configURL: configURL); self.store = store
        store.reload()
        let damaged = Data("{ \"commands\": [ { \"name\": \"half-edited\", } ] ".utf8)
        try damaged.write(to: configURL, options: .atomic)
        store.reload()
        XCTAssertNotNil(store.error)

        // A UI change while the file is damaged (a tab switch writes lastSection automatically).
        store.updatePanel { $0.lastSection = PanelSection.monitoring.rawValue }

        let preserved = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent != "config.json" }
            .compactMap { try? Data(contentsOf: $0) }
        XCTAssertTrue(try Data(contentsOf: configURL) == damaged || preserved.contains(damaged),
                      "the user's damaged edit must survive a write from the UI")
        XCTAssertEqual(try Data(contentsOf: configURL), damaged)
        XCTAssertTrue(store.error?.contains(L10n.configChangesNotSaved) == true, "the banner says why nothing is saved")
        XCTAssertEqual(store.config.commands.map(\.name), ["valid"], "the last valid version stays in memory")

        // The user fixes the file: it is picked up and writes work again.
        try ConfigCodec.encode(Config(commands: [Command(name: "fixed", command: "true")])).write(to: configURL, options: .atomic)
        store.reload()
        XCTAssertNil(store.error)
        store.updatePanel { $0.lastSection = PanelSection.monitoring.rawValue }
        XCTAssertEqual(try ConfigCodec.decode(Data(contentsOf: configURL)).commands.map(\.name), ["fixed"])
        XCTAssertEqual(try ConfigCodec.decode(Data(contentsOf: configURL)).panel.lastSection, PanelSection.monitoring.rawValue)
    }

    func testMissingConfigIsRecreatedByAUIWrite() throws {
        try ConfigCodec.encode(Config(commands: [Command(name: "valid", command: "true")])).write(to: configURL)
        let store = CommandStore(configURL: configURL); self.store = store
        store.reload()
        try FileManager.default.removeItem(at: configURL)
        store.reload()
        XCTAssertNotNil(store.error)
        store.setGlobalHotkey(true)
        XCTAssertEqual(try ConfigCodec.decode(Data(contentsOf: configURL)).commands.map(\.name), ["valid"],
                       "no user data in a missing file: the UI write restores it")
    }

    func testRecoveryLeavesConfigAndSessionSnapshotUntouched() throws {
        let config = try ConfigCodec.encode(Config(commands: [Command(name: "keep", command: "true")]))
        try config.write(to: configURL)
        let snapshotURL = directory.appendingPathComponent("claude-tabs.json")
        let snapshot = Data("{\"tabs\":[{\"sessionID\":\"only-copy\"}]}".utf8)
        try snapshot.write(to: snapshotURL)
        let markersURL = directory.appendingPathComponent("recovery-markers")
        let storage = FileRecoveryStorage(url: directory.appendingPathComponent("recovery.json"))

        // Three early crashes in a row, then the user turns everything back on.
        for _ in 0..<4 {
            let recovery = RecoveryModel(storage: storage, markers: FileRecoveryMarkerStorage(url: markersURL),
                                         bootTime: { 42 }, installedBuild: "1", notify: { _ in })
            recovery.launch()
            recovery.begin(.tabRestore); recovery.end(.tabRestore)
        }
        let recovery = RecoveryModel(storage: storage, markers: FileRecoveryMarkerStorage(url: markersURL),
                                     bootTime: { 42 }, installedBuild: "1", notify: { _ in })
        recovery.launch()
        XCTAssertTrue(recovery.hasSuspensions)
        recovery.resumeAll()
        recovery.markCleanExit()

        XCTAssertEqual(try Data(contentsOf: configURL), config)
        XCTAssertEqual(try Data(contentsOf: snapshotURL), snapshot)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        XCTAssertEqual(names, ["claude-tabs.json", "config.json", "recovery-markers", "recovery.json"])
    }
}
