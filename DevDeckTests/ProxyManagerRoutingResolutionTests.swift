import XCTest
@testable import DevDeck

/// `ProxyManager.routing(for:)` — the verdict `ProcessManager` acts on. The rule that matters:
/// a flagged command NEVER resolves to "just run it directly".
@MainActor
final class ProxyManagerRoutingResolutionTests: XCTestCase {

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

    private func makeManager(credentials: FakeProxyCredentialStore = FakeProxyCredentialStore())
    -> (ProxyManager, CommandStore, FakeProxyDiscovering) {
        let store = CommandStore(configURL: url)
        let discovering = FakeProxyDiscovering()
        let manager = ProxyManager(discovering: discovering,
                                   advertiser: FakeProxyAdvertising(),
                                   credentials: credentials)
        manager.store = store
        return (manager, store, discovering)
    }

    private func flagged() -> Command {
        Command(id: UUID(), name: "claude", command: "claude", routeThroughProxy: true)
    }

    func testUnflaggedCommandIsNotRouted() {
        let (manager, _, _) = makeManager()
        let plain = Command(id: UUID(), name: "build", command: "just build")

        XCTAssertEqual(manager.routing(for: plain), .notRouted)
    }

    func testNoActiveProxyIsUnavailableNotDirect() {
        let (manager, _, _) = makeManager()

        XCTAssertEqual(manager.routing(for: flagged()), .unavailable,
                       "the flag exists to prevent leaking past the VPN — never fall back to direct")
    }

    func testActiveOpenProxyRoutes() async {
        let (manager, store, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "personal-mac", host: "192.168.1.42", port: 9999,
                                  authRequired: false, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        store.setActiveProxy(name: "personal-mac")

        XCTAssertEqual(manager.routing(for: flagged()),
                       .routed(env: proxyEnv(host: "192.168.1.42", port: 9999, user: nil, pass: nil)))
    }

    func testAuthProxyWithoutCredentialsIsUnavailable() async {
        let (manager, store, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "locked", host: "10.0.0.9", port: 8888,
                                  authRequired: true, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        store.setActiveProxy(name: "locked")

        XCTAssertEqual(manager.routing(for: flagged()), .unavailable, "no username, no password")

        // Username alone isn't enough — the password lives in the Keychain.
        store.setActiveProxy(name: "locked", username: "dev")
        XCTAssertEqual(manager.routing(for: flagged()), .unavailable, "username without a password")
    }

    func testAuthProxyWithCredentialsRoutes() async {
        let credentials = FakeProxyCredentialStore([ProxyCredentialAccount.client("locked"): "s3cret"])
        let (manager, store, fake) = makeManager(credentials: credentials)
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "locked", host: "10.0.0.9", port: 8888,
                                  authRequired: true, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        store.setActiveProxy(name: "locked", username: "dev")

        XCTAssertEqual(manager.routing(for: flagged()),
                       .routed(env: proxyEnv(host: "10.0.0.9", port: 8888, user: "dev", pass: "s3cret")))
    }

    func testSelectedButOfflinePeerIsUnavailable() async {
        let (manager, store, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "personal-mac", host: "192.168.1.42", port: 9999,
                                  authRequired: false, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        store.setActiveProxy(name: "personal-mac")
        XCTAssertNotEqual(manager.routing(for: flagged()), .unavailable)

        fake.emit([])   // the sharing Mac went to sleep
        await yieldUntil { manager.discovered.isEmpty }

        XCTAssertEqual(manager.routing(for: flagged()), .unavailable)
    }
}
