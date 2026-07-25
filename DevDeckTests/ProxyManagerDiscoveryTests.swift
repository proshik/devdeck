import XCTest
@testable import DevDeck

/// Client-side discovery: the push stream updates the list, and the active choice resolves by
/// Bonjour NAME (so a peer's IP can change freely — the whole point of the feature).
@MainActor
final class ProxyManagerDiscoveryTests: XCTestCase {

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

    /// `discoveryEnabled` mirrors the Settings toggle: the remembered endpoint only resolves while
    /// discovery is on, so the rig turns it on exactly as every app path that starts browsing does.
    private func makeManager(
        discovering: FakeProxyDiscovering = FakeProxyDiscovering(),
        credentials: FakeProxyCredentialStore = FakeProxyCredentialStore(),
        discoveryEnabled: Bool = true
    ) -> (ProxyManager, CommandStore, FakeProxyDiscovering) {
        let store = CommandStore(configURL: url)
        store.setProxyDiscoveryEnabled(discoveryEnabled)
        let manager = ProxyManager(discovering: discovering,
                                   advertiser: FakeProxyAdvertising(),
                                   credentials: credentials)
        manager.store = store
        return (manager, store, discovering)
    }

    private func proxy(_ name: String, host: String = "192.168.1.42", port: Int = 9999,
                       auth: Bool = false, exitIP: String? = nil) -> DiscoveredProxy {
        DiscoveredProxy(name: name, host: host, port: port, authRequired: auth,
                        exitIP: exitIP, proto: "http+socks", schema: 1)
    }

    func testDiscoveredListFollowsTheBrowseStream() async {
        let (manager, _, fake) = makeManager()
        manager.startDiscovery()

        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        XCTAssertEqual(manager.discovered.first?.name, "personal-mac")

        // Bonjour always reports the FULL set — a peer going away shrinks the list.
        fake.emit([proxy("personal-mac"), proxy("laptop", host: "192.168.1.50")])
        await yieldUntil { manager.discovered.count == 2 }
        fake.emit([])
        await yieldUntil { manager.discovered.isEmpty }
    }

    func testActiveProxyResolvesByName() async {
        let (manager, store, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac"), proxy("laptop", host: "192.168.1.50")])
        await yieldUntil { manager.discovered.count == 2 }

        store.setActiveProxy(name: "laptop")
        XCTAssertEqual(manager.activeProxy?.host, "192.168.1.50")

        // The peer reconnects on a NEW IP — same Bonjour name, so the choice still resolves.
        fake.emit([proxy("laptop", host: "192.168.1.77")])
        await yieldUntil { manager.activeProxy?.host == "192.168.1.77" }
    }

    func testActiveProxyIsNilWhenTheChosenPeerDisappears() async {
        let (manager, store, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        store.setActiveProxy(name: "personal-mac")
        XCTAssertNotNil(manager.activeProxy)

        fake.emit([proxy("laptop")])
        await yieldUntil { manager.discovered.map(\.name) == ["laptop"] }
        XCTAssertNil(manager.activeProxy, "the selection is kept but does not resolve while offline")
        XCTAssertEqual(store.config.settings.activeProxyName, "personal-mac")
    }

    func testActiveProxyIsNilWithoutASelection() async {
        let (manager, _, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }

        XCTAssertNil(manager.activeProxy)
    }

    func testStopDiscoveryClearsTheListAndStopsTheBrowser() async {
        let (manager, _, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }

        manager.stopDiscovery()

        XCTAssertTrue(manager.discovered.isEmpty)
        XCTAssertEqual(fake.stopCount, 1)
    }

    func testDisabledDiscoveryNeverStartsTheBrowser() {
        let (manager, _, fake) = makeManager(discoveryEnabled: false)
        // proxyDiscoveryEnabled off → start() must not open a browse stream at all
        // (no Local Network prompt, no mDNS chatter for users who don't use the feature).
        manager.start()

        XCTAssertEqual(fake.resultsCallCount, 0)
        XCTAssertTrue(manager.discovered.isEmpty)
    }

    func testStartDiscoveryIsIdempotent() {
        let (manager, _, fake) = makeManager()
        manager.startDiscovery()
        manager.startDiscovery()

        XCTAssertEqual(fake.resultsCallCount, 1, "a second call must not open a second browser")
    }

    func testSwitchingToADifferentPeerDropsTheStaleUsername() async {
        let (manager, store, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac", auth: true), proxy("laptop", auth: true)])
        await yieldUntil { manager.discovered.count == 2 }

        manager.setActiveProxy(proxy("personal-mac", auth: true))
        manager.setClientCredentials(username: "dev", password: "s3cret", for: "personal-mac")
        XCTAssertEqual(store.config.settings.activeProxyUsername, "dev")

        manager.setActiveProxy(proxy("laptop", auth: true))
        XCTAssertNil(store.config.settings.activeProxyUsername,
                     "credentials are per-peer — reusing another host's login would just fail")
    }

    func testActiveProxyNeedsCredentialsOnlyForAuthPeersWithoutStoredLogin() async {
        let credentials = FakeProxyCredentialStore()
        // `store` must stay bound: ProxyManager holds it weakly (AppDelegate owns it in the app).
        let (manager, store, fake) = makeManager(credentials: credentials)
        manager.startDiscovery()
        fake.emit([proxy("open-mac"), proxy("locked-mac", auth: true)])
        await yieldUntil { manager.discovered.count == 2 }

        manager.setActiveProxy(proxy("open-mac"))
        XCTAssertFalse(manager.activeProxyNeedsCredentials, "an open proxy needs nothing")

        manager.setActiveProxy(proxy("locked-mac", auth: true))
        XCTAssertTrue(manager.activeProxyNeedsCredentials)

        manager.setClientCredentials(username: "dev", password: "s3cret", for: "locked-mac")
        XCTAssertFalse(manager.activeProxyNeedsCredentials)
        XCTAssertEqual(store.config.settings.activeProxyUsername, "dev", "the username is persisted…")
        XCTAssertEqual(credentials.password(for: ProxyCredentialAccount.client("locked-mac")), "s3cret",
                       "…and the password goes to the credential store, not the config")
    }

    /// Same as `makeManager`, but retains the store for the whole test — `ProxyManager.store` is
    /// weak (AppDelegate owns it in the app), so a dropped binding would silently deallocate it.
    private var retainedStore: CommandStore?

    private func makeManagerKeepingStore() -> (ProxyManager, CommandStore, FakeProxyDiscovering) {
        let made = makeManager()
        retainedStore = made.1
        return made
    }

    func testRemembersTheEndpointOfTheActiveProxy() async {
        let (manager, store, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }

        manager.setActiveProxy(proxy("personal-mac"))

        XCTAssertEqual(store.config.settings.activeProxyHost, "192.168.1.42")
        XCTAssertEqual(store.config.settings.activeProxyPort, 9999)
    }

    func testFallsBackToTheRememberedEndpointWhenBonjourGoesQuiet() async {
        // The work Mac's corporate VPN filters multicast: the announcement disappears while the
        // proxy stays reachable over unicast TCP. Verified live on 2026-07-25.
        let (manager, _, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))

        fake.emit([])
        await yieldUntil { manager.discovered.isEmpty }

        let active = try! XCTUnwrap(manager.activeProxy)
        XCTAssertEqual(active.host, "192.168.1.42")
        XCTAssertEqual(active.port, 9999)
        XCTAssertFalse(active.isLive, "marked as remembered so the UI can say so")
    }

    func testLiveAnnouncementWinsOverTheRememberedEndpoint() async {
        let (manager, _, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac", host: "192.168.1.42")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac", host: "192.168.1.42"))

        // The peer comes back on a new address — live data must override the cached one.
        fake.emit([proxy("personal-mac", host: "192.168.1.77")])
        await yieldUntil { manager.activeProxy?.host == "192.168.1.77" }

        XCTAssertTrue(manager.activeProxy?.isLive == true)
    }

    func testDiscoveryUpdatesRefreshTheRememberedEndpoint() async {
        let (manager, store, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac", host: "192.168.1.42")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac", host: "192.168.1.42"))

        fake.emit([proxy("personal-mac", host: "192.168.1.77")])
        await yieldUntil { store.config.settings.activeProxyHost == "192.168.1.77" }

        XCTAssertEqual(store.config.settings.activeProxyHost, "192.168.1.77")
    }

    func testReadingActiveProxyNeverWritesTheConfig() async {
        let (manager, store, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))
        let before = try! FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        // SwiftUI evaluates this during `body`; a write here would hit the disk on every render.
        for _ in 0..<20 { _ = manager.activeProxy }

        let after = try! FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    func testVisibleProxiesIncludesTheRememberedActiveProxy() async {
        let (manager, _, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))

        fake.emit([])
        await yieldUntil { manager.discovered.isEmpty }

        XCTAssertEqual(manager.visibleProxies.map(\.name), ["personal-mac"],
                       "a proxy that went quiet must not vanish from the list without explanation")
        XCTAssertFalse(manager.visibleProxies[0].isLive)
    }

    func testVisibleProxiesHasNoDuplicateWhenTheActiveProxyIsLive() async {
        let (manager, _, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac"), proxy("laptop")])
        await yieldUntil { manager.discovered.count == 2 }
        manager.setActiveProxy(proxy("personal-mac"))

        XCTAssertEqual(manager.visibleProxies.count, 2)
    }
}
