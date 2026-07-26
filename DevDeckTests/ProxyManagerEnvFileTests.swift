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
    /// `lanIP` is a closure (not a fixed value) so a test can flip the answer mid-run — see
    /// `testNoLANAddressRemovesTheFile`, which needs the address to disappear after the file exists.
    private func makeRig(lanIP: @escaping () -> String? = { "192.168.31.84" },
                         credentials: FakeProxyCredentialStore = FakeProxyCredentialStore())
    -> (ProxyManager, CommandStore, FakeProxyDiscovering, FakeProxyEnvFile) {
        let store = CommandStore(configURL: url)
        store.setProxyDiscoveryEnabled(true)
        let discovering = FakeProxyDiscovering()
        let envFile = FakeProxyEnvFile()
        let manager = ProxyManager(discovering: discovering,
                                   advertiser: FakeProxyAdvertising(),
                                   credentials: credentials,
                                   lanIP: lanIP,
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
        // Written first, WITH a LAN address, so the later nil assertion can only pass because the
        // guard correctly reacted to the address disappearing — not because nothing was ever wired up.
        var lanIP: String? = "192.168.31.84"
        let (manager, _, fake, envFile) = makeRig(lanIP: { lanIP })
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))
        XCTAssertNotNil(envFile.contents, "sanity: written while a LAN address is known")

        lanIP = nil   // Wi-Fi off / only a VPN tunnel is up: which LAN we are on is unknown
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
        // Written first, WITH credentials, so the later nil assertion can only pass because the
        // guard correctly reacted to losing them — not because nothing was ever wired up.
        let credentials = FakeProxyCredentialStore()
        let (manager, _, fake, envFile) = makeRig(credentials: credentials)
        manager.startDiscovery()
        fake.emit([proxy("locked", auth: true)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("locked", auth: true))
        manager.setClientCredentials(username: "dev", password: "s3cret", for: "locked")
        XCTAssertNotNil(envFile.contents, "sanity: written once credentials make the proxy usable")

        manager.setClientCredentials(username: "", password: nil, for: "locked")

        XCTAssertNil(envFile.contents, "same verdict as routing(for:) — unusable means no file")
        XCTAssertEqual(manager.routing(for: Command(id: UUID(), name: "c", command: "c",
                                                    routeThroughProxy: true)), .unavailable)
    }

    /// A removal that FAILS (full disk, read-only home) must not advance the cache: believing the
    /// file is gone when it still grants proxy access — and holds the plaintext password — is
    /// fail-open on the very control the design calls the safe state, with nothing left to retry it.
    func testAFailedRemovalIsRetriedOnTheNextRefresh() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))
        XCTAssertNotNil(envFile.contents, "sanity: the file is there before we deselect")

        envFile.removeSucceeds = false
        manager.setActiveProxy(nil)
        let attempts = envFile.removeCount

        XCTAssertGreaterThan(attempts, 0, "sanity: removal was attempted")
        XCTAssertNotNil(envFile.contents, "sanity: the file is still on disk — the removal failed")

        // Next refresh: it must try again rather than trust a cache it never got to update.
        envFile.removeSucceeds = true
        fake.emit([proxy("personal-mac")])
        await yieldUntil({ envFile.contents == nil }, message: "a failed removal was never retried")

        XCTAssertGreaterThan(envFile.removeCount, attempts)
    }

    /// A failed WRITE has the same shape in the milder direction: the endpoint on disk is stale
    /// while DevDeck considers it current, so the next refresh must write again.
    func testAFailedWriteIsRetriedOnTheNextRefresh() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        envFile.writeSucceeds = false
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))
        let attempts = envFile.writeCount

        XCTAssertGreaterThan(attempts, 0, "sanity: a write was attempted")
        XCTAssertNil(envFile.contents, "sanity: nothing landed — the write failed")

        envFile.writeSucceeds = true
        fake.emit([proxy("personal-mac")])
        await yieldUntil({ envFile.contents != nil }, message: "a failed write was never retried")

        XCTAssertGreaterThan(envFile.writeCount, attempts)
    }

    /// `config.json` is hand-editable and the `FileWatcher` reloads it, so deselecting the proxy
    /// there must reach the terminal helper too — `routing(for:)` already honours it immediately.
    /// Without the settings observation the file kept granting access until the next browse update,
    /// which on a quiet network never arrives.
    func testAnExternalConfigEditRemovesTheFile() async {
        let (manager, store, fake, envFile) = makeRig()
        manager.start()   // arms the settings observation, as AppDelegate does
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))
        XCTAssertNotNil(envFile.contents, "sanity: the file is there before the edit")

        // Straight through the store — exactly what a reload from a hand-edited file produces,
        // with no ProxyManager method involved.
        store.setActiveProxy(name: nil)

        await yieldUntil({ envFile.contents == nil },
                         message: "an external deselection left proxy.env usable")
        XCTAssertEqual(manager.routing(for: Command(id: UUID(), name: "c", command: "c",
                                                    routeThroughProxy: true)), .unavailable,
                       "and the in-app verdict agrees")
    }

    /// Crash recovery: `lastProxyEnvContents` starts nil in every new `ProxyManager`, same as it
    /// would after a real crash or force-quit. If the removal guard trusted that nil the way it
    /// trusts it on every LATER call, a file left by a previous process — possibly holding a
    /// plaintext proxy password — would survive indefinitely because this instance never believed
    /// it existed. The first refresh of a session must establish ground truth on disk instead.
    func testStartWithNoActiveProxyRemovesAStaleFileFromAPreviousSession() {
        let (manager, _, _, envFile) = makeRig()

        manager.start()

        XCTAssertGreaterThan(envFile.removeCount, 0,
                             "a fresh process must not trust an uninitialized cache over the real file")
        XCTAssertNil(envFile.contents)
    }
}
