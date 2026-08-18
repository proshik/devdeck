import XCTest
@testable import DevDeck

/// The proxied-browser launch: a separate Chrome instance whose traffic egresses through the
/// ACTIVE proxy — the missing half of Claude Code's `/login`, whose OAuth page opens in a
/// browser that otherwise goes direct.
@MainActor
final class ProxyBrowserTests: XCTestCase {

    func testArgumentsAreExactlyTheProxyTriple() {
        XCTAssertEqual(
            proxyBrowserArguments(proxyURL: "http://127.0.0.1:18888", profileDir: "/tmp/Profile Dir"),
            ["--proxy-server=http://127.0.0.1:18888",
             "--proxy-bypass-list=localhost;127.0.0.1",
             "--user-data-dir=/tmp/Profile Dir"],
            "bypass keeps the OAuth localhost callback direct; the profile isolates the instance")
    }

    // MARK: - The manager hook

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

    private final class LaunchRecorder: @unchecked Sendable {
        var launches: [[String]] = []
    }

    private func makeManager(recorder: LaunchRecorder) -> (ProxyManager, CommandStore) {
        let store = CommandStore(configURL: url)
        let manager = ProxyManager(
            discovering: FakeProxyDiscovering(),
            advertiser: FakeProxyAdvertising(),
            credentials: FakeProxyCredentialStore(),
            lanIP: { "192.168.1.42" },
            gostPath: { _ in nil },
            exitIPProbe: { _ in nil },
            exitIPRetryDelay: .milliseconds(1),
            envFile: FakePrivateFile(),
            shareConfigFile: FakePrivateFile(),
            bridgeConfigFile: FakePrivateFile(),
            browserLauncher: { args in recorder.launches.append(args); return true }
        )
        manager.store = store
        return (manager, store)
    }

    func testNoUsableProxyMeansNoLaunchAndDisabledButton() {
        let recorder = LaunchRecorder()
        let (manager, _) = makeManager(recorder: recorder)

        XCTAssertFalse(manager.canOpenProxyBrowser)
        manager.openProxyBrowser()

        XCTAssertTrue(recorder.launches.isEmpty, "no resolved proxy — nothing to point a browser at")
    }

    func testLaunchCarriesTheResolvedProxyURL() {
        let recorder = LaunchRecorder()
        let (manager, store) = makeManager(recorder: recorder)
        // A remembered discovered proxy on the current LAN resolves without any Bonjour traffic.
        store.setActiveProxy(name: "colleague-mac")
        store.rememberActiveProxyEndpoint(host: "192.168.1.5", port: 9999,
                                          authRequired: false, lanPrefix: "192.168.1")
        store.setProxyDiscoveryEnabled(true)

        XCTAssertTrue(manager.canOpenProxyBrowser)
        manager.openProxyBrowser()

        XCTAssertEqual(recorder.launches.count, 1)
        XCTAssertEqual(recorder.launches.first?.first, "--proxy-server=http://192.168.1.5:9999")
        XCTAssertEqual(recorder.launches.first?.last,
                       "--user-data-dir=\(proxyBrowserProfileURL.path)")
    }
}
