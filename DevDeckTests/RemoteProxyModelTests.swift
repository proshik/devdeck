import XCTest
@testable import DevDeck

/// `RemoteProxy` persistence and the exclusivity of the two selection kinds: exactly one of
/// `activeProxyName` (discovered) and `activeRemoteProxyID` (remote) is ever set.
@MainActor
final class RemoteProxyModelTests: XCTestCase {

    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeStore() -> CommandStore { CommandStore(configURL: url) }

    // MARK: - Decoding

    func testEmptyObjectDecodesToDefaults() throws {
        let proxy = try JSONDecoder().decode(RemoteProxy.self, from: Data("{}".utf8))
        XCTAssertEqual(proxy.localPort, 18888)
        XCTAssertEqual(proxy.socksPort, 1080)
        XCTAssertEqual(proxy.name, "")
        XCTAssertNil(proxy.tunnelCommandID)
    }

    func testConfigRoundTripsRemoteProxies() throws {
        let tunnelID = UUID()
        var config = Config()
        config.remoteProxies = [RemoteProxy(name: "vds", localPort: 28888, socksPort: 2080,
                                            tunnelCommandID: tunnelID)]
        config.settings.activeRemoteProxyID = config.remoteProxies[0].id
        let data = try JSONEncoder().encode(config)
        let back = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(back.remoteProxies, config.remoteProxies)
        XCTAssertEqual(back.settings.activeRemoteProxyID, config.remoteProxies[0].id)
    }

    func testConfigWithoutRemoteProxiesDecodesEmpty() throws {
        let config = try JSONDecoder().decode(Config.self, from: Data(#"{"commands": []}"#.utf8))
        XCTAssertEqual(config.remoteProxies, [])
        XCTAssertNil(config.settings.activeRemoteProxyID)
    }

    // MARK: - Selection exclusivity

    func testSelectingRemoteClearsDiscoveredChoiceAndItsEndpointCache() {
        let store = makeStore()
        let remote = RemoteProxy(name: "vds")
        store.upsertRemoteProxy(remote)
        store.setActiveProxy(name: "colleague-mac", username: "dev")
        store.rememberActiveProxyEndpoint(host: "192.168.1.5", port: 9999,
                                          authRequired: true, lanPrefix: "192.168.1")

        store.setActiveRemoteProxy(id: remote.id)

        XCTAssertEqual(store.config.settings.activeRemoteProxyID, remote.id)
        XCTAssertNil(store.config.settings.activeProxyName)
        XCTAssertNil(store.config.settings.activeProxyUsername)
        XCTAssertNil(store.config.settings.activeProxyHost)
        XCTAssertNil(store.config.settings.activeProxyPort)
        XCTAssertNil(store.config.settings.activeProxyLANPrefix)
        XCTAssertFalse(store.config.settings.activeProxyAuthRequired)
    }

    func testSelectingDiscoveredClearsRemoteChoice() {
        let store = makeStore()
        let remote = RemoteProxy(name: "vds")
        store.upsertRemoteProxy(remote)
        store.setActiveRemoteProxy(id: remote.id)

        store.setActiveProxy(name: "colleague-mac")

        XCTAssertEqual(store.config.settings.activeProxyName, "colleague-mac")
        XCTAssertNil(store.config.settings.activeRemoteProxyID)
    }

    func testDeletingTheActiveRemoteProxyClearsTheSelection() {
        let store = makeStore()
        let remote = RemoteProxy(name: "vds")
        store.upsertRemoteProxy(remote)
        store.setActiveRemoteProxy(id: remote.id)

        store.deleteRemoteProxy(id: remote.id)

        XCTAssertTrue(store.config.remoteProxies.isEmpty)
        XCTAssertNil(store.config.settings.activeRemoteProxyID)
    }

    func testUpsertReplacesById() {
        let store = makeStore()
        var remote = RemoteProxy(name: "vds")
        store.upsertRemoteProxy(remote)
        remote.localPort = 28888
        store.upsertRemoteProxy(remote)

        XCTAssertEqual(store.config.remoteProxies.count, 1)
        XCTAssertEqual(store.config.remoteProxies.first?.localPort, 28888)
    }
}
