import XCTest
@testable import DevDeck

/// Client side: the popover's "check" button — one probe through the ACTIVE proxy from this
/// machine, published as `clientCheck` so the row can show the measured egress IP. The check must
/// go through exactly what `routing(for:)` would hand a flagged command (same endpoint, same
/// credentials), or a green check would prove nothing about the runs.
@MainActor
final class ProxyManagerClientCheckTests: XCTestCase {

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

    /// Records every URL it is asked to probe and answers with a fixed response. Optionally gated:
    /// a `blocked` probe parks on a semaphore until `release()`, which is how the tests pin the
    /// `.running` state and race a stale result against a proxy switch.
    private final class RecordingProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let gate = DispatchSemaphore(value: 0)
        private let blocked: Bool
        private let response: String?
        private var calls: [String] = []

        init(response: String?, blocked: Bool = false) {
            self.response = response
            self.blocked = blocked
        }

        var probedURLs: [String] { lock.lock(); defer { lock.unlock() }; return calls }

        func release() { gate.signal() }

        func probe(_ url: String) -> String? {
            lock.lock(); calls.append(url); lock.unlock()
            if blocked { gate.wait() }
            return response
        }
    }

    /// The store is retained by the test (`ProxyManager.store` is weak — AppDelegate owns it in
    /// the app); dropping it would deallocate the config mid-test.
    private var retainedStore: CommandStore?

    private func makeManager(probe: RecordingProbe,
                             credentials: FakeProxyCredentialStore = FakeProxyCredentialStore())
    -> (ProxyManager, CommandStore, FakeProxyDiscovering) {
        let store = CommandStore(configURL: url)
        store.setProxyDiscoveryEnabled(true)
        retainedStore = store
        let discovering = FakeProxyDiscovering()
        let manager = ProxyManager(discovering: discovering,
                                   advertiser: FakeProxyAdvertising(),
                                   credentials: credentials,
                                   lanIP: { "192.168.31.10" },
                                   exitIPProbe: { probe.probe($0) },
                                   envFile: FakePrivateFile())
        manager.store = store
        return (manager, store, discovering)
    }

    /// Emit one open proxy and make it active.
    private func activateOpenProxy(_ manager: ProxyManager, _ fake: FakeProxyDiscovering) async {
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "personal-mac", host: "192.168.31.117", port: 9999,
                                   authRequired: false, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(manager.discovered[0])
    }

    func testCheckSuccessPublishesTheMeasuredIP() async {
        let probe = RecordingProbe(response: "78.40.193.132\n")
        let (manager, _, fake) = makeManager(probe: probe)
        await activateOpenProxy(manager, fake)

        manager.checkActiveProxy()
        await sleepUntil { manager.clientCheck != .running }

        XCTAssertEqual(manager.clientCheck, .success("78.40.193.132"),
                       "trailing newline from curl is trimmed")
        XCTAssertEqual(probe.probedURLs, ["http://192.168.31.117:9999"],
                       "the probe dials the proxy the routing would use — one attempt, no retries")
    }

    func testCheckShowsRunningWhileTheProbeIsInFlight() async {
        let probe = RecordingProbe(response: "78.40.193.132", blocked: true)
        let (manager, _, fake) = makeManager(probe: probe)
        await activateOpenProxy(manager, fake)

        manager.checkActiveProxy()

        XCTAssertEqual(manager.clientCheck, .running, "the button shows a spinner immediately")
        probe.release()
        await sleepUntil { manager.clientCheck == .success("78.40.193.132") }
    }

    func testCheckFailurePublishesFailed() async {
        // curl prints nothing on connection-refused / timeout — that IS the failure signal.
        let probe = RecordingProbe(response: "")
        let (manager, _, fake) = makeManager(probe: probe)
        await activateOpenProxy(manager, fake)

        manager.checkActiveProxy()
        await sleepUntil { manager.clientCheck == .failed }
    }

    func testCheckSendsTheActiveProxyCredentials() async {
        let probe = RecordingProbe(response: "1.2.3.4")
        let credentials = FakeProxyCredentialStore([ProxyCredentialAccount.client("locked"): "s3cret"])
        let (manager, store, fake) = makeManager(probe: probe, credentials: credentials)
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "locked", host: "192.168.31.117", port: 8888,
                                   authRequired: true, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(manager.discovered[0])
        store.setActiveProxy(name: "locked", username: "dev")

        manager.checkActiveProxy()
        await sleepUntil { manager.clientCheck == .success("1.2.3.4") }

        XCTAssertEqual(probe.probedURLs, ["http://dev:s3cret@192.168.31.117:8888"],
                       "same URL builder as routing — a check that skipped auth would lie")
    }

    func testCheckWithoutAResolvableProxyReportsWhy() {
        let probe = RecordingProbe(response: "unused")
        let (manager, _, _) = makeManager(probe: probe)

        manager.checkActiveProxy()

        XCTAssertEqual(manager.clientCheck, .unavailable(L10n.proxyCheckUnavailableNoProxy),
                       "the button used to go silent here — it must say why instead")
        XCTAssertEqual(probe.probedURLs, [], "no probe without an active proxy")
    }

    func testSwitchingTheActiveProxyResetsTheCheck() async {
        let probe = RecordingProbe(response: "78.40.193.132")
        let (manager, _, fake) = makeManager(probe: probe)
        await activateOpenProxy(manager, fake)
        manager.checkActiveProxy()
        await sleepUntil { manager.clientCheck == .success("78.40.193.132") }

        manager.setActiveProxy(nil)

        XCTAssertEqual(manager.clientCheck, .idle,
                       "a green check for one proxy must not survive onto another")
    }

    func testAStaleInFlightProbeNeverLandsAfterTheSwitch() async {
        let probe = RecordingProbe(response: "78.40.193.132", blocked: true)
        let (manager, _, fake) = makeManager(probe: probe)
        await activateOpenProxy(manager, fake)
        manager.checkActiveProxy()
        XCTAssertEqual(manager.clientCheck, .running)

        manager.setActiveProxy(nil)   // the user deselects while the probe is still out
        probe.release()

        // Give the stale completion every chance to land, then make sure it did not.
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(manager.clientCheck, .idle,
                       "a result for the OLD proxy must not paint the new selection green")
    }
}
