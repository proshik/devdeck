import XCTest
@testable import DevDeck

/// `~/.config/devdeck/proxy.env` must track the same verdict `routing(for:)` gives, or the terminal
/// helper and the app would disagree about whether a proxy is usable.
@MainActor
final class ProxyManagerEnvFileTests: XCTestCase {

    private var dir: URL!
    private var url: URL!
    private var retainedStore: CommandStore?

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        retainedStore = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// The store is retained for the test's lifetime — `ProxyManager.store` is weak.
    private func makeRig(lanIP: String? = "192.168.31.84",
                         credentials: FakeProxyCredentialStore = FakeProxyCredentialStore())
    -> (ProxyManager, CommandStore, FakeProxyDiscovering, FakeProxyEnvFile) {
        let store = CommandStore(configURL: url)
        store.setProxyDiscoveryEnabled(true)
        let discovering = FakeProxyDiscovering()
        let envFile = FakeProxyEnvFile()
        let manager = ProxyManager(discovering: discovering,
                                   advertiser: FakeProxyAdvertising(),
                                   credentials: credentials,
                                   lanIP: { lanIP },
                                   envFile: envFile)
        manager.store = store
        retainedStore = store
        return (manager, store, discovering, envFile)
    }

    private func proxy(_ name: String, host: String = "192.168.31.117", port: Int = 9999,
                       auth: Bool = false) -> DiscoveredProxy {
        DiscoveredProxy(name: name, host: host, port: port, authRequired: auth,
                        exitIP: nil, proto: "http+socks", schema: 1)
    }

    func testWritesTheFileWhenAProxyResolves() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }

        manager.setActiveProxy(proxy("personal-mac"))

        let contents = try! XCTUnwrap(envFile.contents)
        XCTAssertTrue(contents.contains("DEVDECK_PROXY_URL=http://192.168.31.117:9999"))
        XCTAssertTrue(contents.contains("DEVDECK_PROXY_LAN=192.168.31"),
                      "the prefix comes from this machine's own LAN address")
    }

    func testRepeatedBrowseUpdatesDoNotRewriteTheFile() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))
        let writesAfterSelection = envFile.writeCount

        // Bonjour re-emits the same set constantly; an unguarded write would hit the disk each time.
        for _ in 0..<5 {
            fake.emit([proxy("personal-mac")])
            await Task.yield()
        }

        XCTAssertEqual(envFile.writeCount, writesAfterSelection,
                       "an unchanged endpoint must not rewrite the file")
    }

    func testAChangedEndpointDoesRewriteTheFile() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))

        fake.emit([proxy("personal-mac", host: "192.168.31.200")])
        await yieldUntil { manager.activeProxy?.host == "192.168.31.200" }

        XCTAssertTrue(try! XCTUnwrap(envFile.contents).contains("http://192.168.31.200:9999"),
                      "the guard must not suppress a real change")
    }

    func testRemovesTheFileWhenNoProxyResolves() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))
        XCTAssertNotNil(envFile.contents)

        manager.setActiveProxy(nil)

        XCTAssertNil(envFile.contents, "a missing file is the safe state — the helper refuses")
        XCTAssertGreaterThan(envFile.removeCount, 0)
    }

    func testStoppingDiscoveryRemovesTheFile() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))
        XCTAssertNotNil(envFile.contents)

        manager.setDiscoveryEnabled(false)

        XCTAssertNil(envFile.contents, "discovery off must stop the terminal path too, not just the app")
    }

    func testNoLANAddressRemovesTheFile() async {
        let (manager, _, fake, envFile) = makeRig(lanIP: nil)
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }

        manager.setActiveProxy(proxy("personal-mac"))

        XCTAssertNil(envFile.contents, "without a LAN prefix the helper could not verify the network")
    }

    func testCredentialsAreIncludedWhenTheProxyRequiresThem() async {
        let credentials = FakeProxyCredentialStore([ProxyCredentialAccount.client("locked"): "s3cret"])
        let (manager, _, fake, envFile) = makeRig(credentials: credentials)
        manager.startDiscovery()
        fake.emit([proxy("locked", auth: true)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("locked", auth: true))

        // Deliberate trade-off, documented in the design: a terminal helper cannot read the Keychain,
        // so an authenticated proxy puts the password in this 0600 file or is unusable from a shell.
        manager.setClientCredentials(username: "dev", password: "s3cret", for: "locked")

        XCTAssertTrue(try! XCTUnwrap(envFile.contents).contains("http://dev:s3cret@192.168.31.117:9999"))
    }

    func testAuthProxyWithoutCredentialsRemovesTheFile() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("locked", auth: true)])
        await yieldUntil { manager.discovered.count == 1 }

        manager.setActiveProxy(proxy("locked", auth: true))

        XCTAssertNil(envFile.contents, "same verdict as routing(for:) — unusable means no file")
        XCTAssertEqual(manager.routing(for: Command(id: UUID(), name: "c", command: "c",
                                                    routeThroughProxy: true)), .unavailable)
    }
}
