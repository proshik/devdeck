import XCTest
@testable import DevDeck

/// Persistence of the active proxy's last known endpoint — the fallback used when Bonjour goes
/// quiet (a corporate VPN blocks multicast while leaving unicast TCP working).
@MainActor
final class CommandStoreProxyEndpointTests: XCTestCase {

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

    func testRememberEndpointPersists() throws {
        let store = CommandStore(configURL: url)
        store.setActiveProxy(name: "personal-mac")

        store.rememberActiveProxyEndpoint(host: "192.168.31.117", port: 9999, authRequired: false)

        XCTAssertEqual(store.config.settings.activeProxyHost, "192.168.31.117")
        XCTAssertEqual(store.config.settings.activeProxyPort, 9999)

        let fresh = CommandStore(configURL: url)
        fresh.reload()
        XCTAssertEqual(fresh.config.settings.activeProxyHost, "192.168.31.117",
                       "survives a restart — that is the whole point")
    }

    func testRepeatedIdenticalRememberDoesNotRewriteTheFile() throws {
        let store = CommandStore(configURL: url)
        store.rememberActiveProxyEndpoint(host: "192.168.31.117", port: 9999, authRequired: false)
        let firstWrite = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        // Every Bonjour browse update calls this; an unguarded write would hit the disk constantly.
        for _ in 0..<5 {
            store.rememberActiveProxyEndpoint(host: "192.168.31.117", port: 9999, authRequired: false)
        }
        let lastWrite = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        XCTAssertEqual(firstWrite, lastWrite, "an unchanged endpoint must not touch the file")
    }

    func testChangedEndpointIsPersisted() {
        let store = CommandStore(configURL: url)
        store.rememberActiveProxyEndpoint(host: "192.168.31.117", port: 9999, authRequired: false)

        store.rememberActiveProxyEndpoint(host: "192.168.31.200", port: 8888, authRequired: true)

        XCTAssertEqual(store.config.settings.activeProxyHost, "192.168.31.200")
        XCTAssertEqual(store.config.settings.activeProxyPort, 8888)
        XCTAssertTrue(store.config.settings.activeProxyAuthRequired)
    }

    func testDeselectingTheProxyClearsTheEndpoint() {
        let store = CommandStore(configURL: url)
        store.setActiveProxy(name: "personal-mac", username: "dev")
        store.rememberActiveProxyEndpoint(host: "192.168.31.117", port: 9999, authRequired: true)

        store.setActiveProxy(name: nil, username: nil)

        XCTAssertNil(store.config.settings.activeProxyName)
        XCTAssertNil(store.config.settings.activeProxyHost, "a stale endpoint must not outlive the choice")
        XCTAssertNil(store.config.settings.activeProxyPort)
        XCTAssertFalse(store.config.settings.activeProxyAuthRequired)
    }
}
