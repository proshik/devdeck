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

    /// Discovery is turned on as every app path that starts browsing does — the remembered endpoint
    /// only resolves while it is. `lanIP` is injected (never the machine's real interfaces) because
    /// that endpoint is also scoped to the LAN it was learned on.
    private func makeManager(credentials: FakeProxyCredentialStore = FakeProxyCredentialStore(),
                             lanIP: @escaping () -> String? = { "192.168.31.10" })
    -> (ProxyManager, CommandStore, FakeProxyDiscovering) {
        let store = CommandStore(configURL: url)
        store.setProxyDiscoveryEnabled(true)
        let discovering = FakeProxyDiscovering()
        let manager = ProxyManager(discovering: discovering,
                                   advertiser: FakeProxyAdvertising(),
                                   credentials: credentials,
                                   lanIP: lanIP,
                                   envFile: FakeProxyEnvFile())
        manager.store = store
        return (manager, store, discovering)
    }

    /// Same as `makeManager`, but retains the store for the whole test — `ProxyManager.store` is
    /// weak (AppDelegate owns it in the app), so a dropped binding would silently deallocate it and
    /// surface later as an unrelated assertion failure.
    private var retainedStore: CommandStore?

    private func makeManagerKeepingStore(
        credentials: FakeProxyCredentialStore = FakeProxyCredentialStore(),
        lanIP: @escaping () -> String? = { "192.168.31.10" }
    ) -> (ProxyManager, CommandStore, FakeProxyDiscovering) {
        let made = makeManager(credentials: credentials, lanIP: lanIP)
        retainedStore = made.1
        return made
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

    /// The shape of a config written by 0.5.0: a selection with no cached endpoint next to it —
    /// hence the selection through the STORE, which is the only thing that produces it. Every path
    /// in the app goes through `ProxyManager.setActiveProxy`, which also caches the address, and
    /// then an offline peer keeps routing (see the remembered-endpoint tests below).
    func testSelectionWithoutACachedEndpointIsUnavailableOffline() async {
        let (manager, store, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "personal-mac", host: "192.168.1.42", port: 9999,
                                  authRequired: false, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        store.setActiveProxy(name: "personal-mac")
        XCTAssertNotEqual(manager.routing(for: flagged()), .unavailable)

        fake.emit([])
        await yieldUntil { manager.discovered.isEmpty }

        XCTAssertEqual(manager.routing(for: flagged()), .unavailable,
                       "no live announcement and nothing cached — a flagged command must fail")
    }

    func testRoutesThroughARememberedEndpoint() async {
        let (manager, _, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "personal-mac", host: "192.168.31.117", port: 9999,
                                  authRequired: false, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(manager.discovered[0])

        fake.emit([])   // corporate VPN blocks multicast; the proxy itself is still up
        await yieldUntil { manager.discovered.isEmpty }

        XCTAssertEqual(manager.routing(for: flagged()),
                       .routed(env: proxyEnv(host: "192.168.31.117", port: 9999, user: nil, pass: nil)))
    }

    func testDisablingDiscoveryStopsRoutingThroughTheRememberedEndpoint() async {
        let (manager, _, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "personal-mac", host: "192.168.31.117", port: 9999,
                                  authRequired: false, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(manager.discovered[0])

        fake.emit([])   // the announcement is gone; the remembered endpoint carries the routing
        await yieldUntil { manager.discovered.isEmpty }
        XCTAssertEqual(manager.routing(for: flagged()),
                       .routed(env: proxyEnv(host: "192.168.31.117", port: 9999, user: nil, pass: nil)))

        manager.setDiscoveryEnabled(false)

        XCTAssertNil(manager.activeProxy, "the UI says “no active proxy” — routing must agree")
        XCTAssertEqual(manager.routing(for: flagged()), .unavailable,
                       "switching discovery off must stop routing, not keep a remembered proxy alive")
    }

    func testRememberedEndpointResolvesBackOnTheSameLAN() async {
        // Same Wi-Fi as when the address was learned — the cache is exactly what it is for.
        let (manager, _, fake) = makeManagerKeepingStore(lanIP: { "192.168.31.10" })
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "personal-mac", host: "192.168.31.117", port: 9999,
                                  authRequired: false, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(manager.discovered[0])

        fake.emit([])
        await yieldUntil { manager.discovered.isEmpty }

        XCTAssertEqual(manager.activeProxy?.host, "192.168.31.117")
        XCTAssertEqual(manager.routing(for: flagged()),
                       .routed(env: proxyEnv(host: "192.168.31.117", port: 9999, user: nil, pass: nil)))
    }

    func testRememberedEndpointIsIgnoredOnADifferentLAN() async {
        // The laptop moves to another network. 192.168.31.117 there is a stranger's machine, and
        // with auth cached we would hand it the proxy password without the user doing anything.
        var lanIP: String? = "192.168.31.10"
        let credentials = FakeProxyCredentialStore([ProxyCredentialAccount.client("personal-mac"): "s3cret"])
        let (manager, _, fake) = makeManagerKeepingStore(credentials: credentials, lanIP: { lanIP })
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "personal-mac", host: "192.168.31.117", port: 9999,
                                  authRequired: true, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(manager.discovered[0])
        manager.setClientCredentials(username: "dev", password: "s3cret", for: "personal-mac")

        fake.emit([])
        await yieldUntil { manager.discovered.isEmpty }
        lanIP = "10.10.5.20"   // café Wi-Fi

        XCTAssertNil(manager.activeProxy, "a remembered address means nothing on another network")
        XCTAssertEqual(manager.routing(for: flagged()), .unavailable,
                       "the proxy password must never be sent to whoever holds that address here")
    }

    func testRememberedEndpointIsIgnoredWithoutALANAddress() async {
        var lanIP: String? = "192.168.31.10"
        let (manager, _, fake) = makeManagerKeepingStore(lanIP: { lanIP })
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "personal-mac", host: "192.168.31.117", port: 9999,
                                  authRequired: false, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(manager.discovered[0])

        fake.emit([])
        await yieldUntil { manager.discovered.isEmpty }
        lanIP = nil   // Wi-Fi off / only a VPN tunnel is up: which LAN we are on is unknown

        XCTAssertNil(manager.activeProxy)
        XCTAssertEqual(manager.routing(for: flagged()), .unavailable, "unknown network → fail safe")
    }

    func testHandEditedNonsenseEndpointIsNotUsed() {
        let (manager, store, _) = makeManagerKeepingStore()
        store.setActiveProxy(name: "personal-mac")

        // config.json is explicitly hand-editable — "http://192.168.31.117:0" is not a proxy.
        store.rememberActiveProxyEndpoint(host: "192.168.31.117", port: 0, authRequired: false,
                                          lanPrefix: "192.168.31")
        XCTAssertEqual(manager.routing(for: flagged()), .unavailable, "port 0")

        store.rememberActiveProxyEndpoint(host: "", port: 9999, authRequired: false,
                                          lanPrefix: "192.168.31")
        XCTAssertEqual(manager.routing(for: flagged()), .unavailable, "empty host")
    }

    func testRememberedAuthProxyWithoutCredentialsStaysUnavailable() async {
        let (manager, _, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "locked", host: "10.0.0.9", port: 8888,
                                  authRequired: true, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(manager.discovered[0])

        fake.emit([])
        await yieldUntil { manager.discovered.isEmpty }

        // Without this the test would also pass if the fallback never resolved at all — and then it
        // would say nothing about the credentials requirement.
        XCTAssertEqual(manager.activeProxy?.authRequired, true,
                       "the remembered endpoint resolved, and remembered that it is locked")
        XCTAssertEqual(manager.routing(for: flagged()), .unavailable,
                       "caching the address must not smuggle past the credentials requirement")
    }
}
