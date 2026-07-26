import XCTest
@testable import DevDeck

/// Host side: the share reuses the existing daemon engine, and the Bonjour announcement is driven
/// by the LISTENER's state — not by the toggle — so watchdog restarts re-announce on their own and
/// a dead gost is never advertised as reachable.
@MainActor
final class ProxyManagerShareTests: XCTestCase {

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

    /// Millisecond supervision so watchdog restarts are exercised for real but fast (as in
    /// `ProcessManagerWatchdogTests`).
    private static let fastPolicy = SupervisionPolicy(
        restartDelays: [.milliseconds(40), .milliseconds(40), .milliseconds(40)],
        stabilityWindow: .milliseconds(150),
        adoptedPollInterval: .milliseconds(30),
        portFreePollInterval: .milliseconds(10),
        portFreeTimeout: .milliseconds(100)
    )

    @MainActor
    private struct Rig {
        let manager: ProxyManager
        let store: CommandStore
        let processManager: ProcessManager
        let runner: FakeCommandRunner
        let advertiser: FakeProxyAdvertising
        let credentials: FakeProxyCredentialStore

        /// The synthetic daemon carries a `port`, so `run` goes through the proactive occupied-port
        /// check (a detached task) before launching — wait for the launch rather than assuming it.
        func awaitLaunch(count: Int = 1) async {
            await sleepUntil({ runner.startedCommandIDs.count >= count },
                             message: "the gost daemon was not launched")
        }

        var controller: FakeCommandRunner.Controller? { runner.controller(for: ProxyShare.daemonID) }
    }

    /// Exit-IP probe that fails the first `failures` calls, then returns `ip` — reproduces the real
    /// behaviour where `gost` has been spawned but has not bound its socket yet.
    private final class FlakyExitIPProbe: @unchecked Sendable {
        private let lock = NSLock()
        private let failures: Int
        private let ip: String
        private var calls = 0

        init(failures: Int, ip: String) {
            self.failures = failures
            self.ip = ip
        }

        var callCount: Int { lock.lock(); defer { lock.unlock() }; return calls }

        func probe(_: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            return calls <= failures ? "" : ip   // curl prints nothing on connection-refused
        }
    }

    private func makeRig(
        gostInstalled: Bool = true,
        lanIP: String? = "192.168.1.42",
        exitIP: String? = nil,
        exitIPProbe: (@Sendable (String) -> String?)? = nil,
        share: ProxyShare = ProxyShare(port: 9999)
    ) -> Rig {
        let store = CommandStore(configURL: url)
        store.upsertProxyShare(share)
        store.setProxyShareEnabled(true)

        let runner = FakeCommandRunner()
        let processManager = ProcessManager(runner: runner, notifier: FakeNotifier(),
                                           reaper: FakeDaemonReaper(),
                                           portInspector: FakePortInspector(),
                                           policy: Self.fastPolicy)
        let advertiser = FakeProxyAdvertising()
        let credentials = FakeProxyCredentialStore()
        let manager = ProxyManager(
            discovering: FakeProxyDiscovering(),
            advertiser: advertiser,
            credentials: credentials,
            lanIP: { lanIP },
            gostPath: { _ in gostInstalled ? "/opt/homebrew/bin/gost" : nil },
            exitIPProbe: exitIPProbe ?? { _ in exitIP },
            exitIPRetryDelay: .milliseconds(1),   // the retry loop is exercised, not waited on
            envFile: FakeProxyEnvFile()
        )
        manager.store = store
        manager.processManager = processManager
        return Rig(manager: manager, store: store, processManager: processManager,
                   runner: runner, advertiser: advertiser, credentials: credentials)
    }

    // MARK: starting the listener

    func testStartShareLaunchesTheSyntheticDaemon() async {
        let rig = makeRig()

        rig.manager.startShare()
        await rig.awaitLaunch()

        XCTAssertEqual(rig.runner.startedCommandIDs, [ProxyShare.daemonID])
        XCTAssertFalse(rig.manager.gostMissing)
        let started = rig.controller?.command
        XCTAssertEqual(started?.command, "/opt/homebrew/bin/gost -L 'auto://:9999'")
        XCTAssertTrue(started?.watchdogEnabled == true)
    }

    func testMissingGostFlagsItAndStartsNothing() async {
        let rig = makeRig(gostInstalled: false)

        rig.manager.startShare()
        await settle()   // a launch would be asynchronous — give it a chance to (not) happen

        XCTAssertTrue(rig.manager.gostMissing)
        XCTAssertTrue(rig.runner.startedCommandIDs.isEmpty, "nothing is launched without gost")
    }

    func testStartShareDoesNotRestartALiveListener() async {
        let rig = makeRig()
        rig.manager.startShare()
        await rig.awaitLaunch()
        rig.controller?.started(pid: 42)
        await yieldUntil { rig.processManager.states[ProxyShare.daemonID] == .daemonRunning }

        rig.manager.startShare()   // e.g. the toggle flipped twice

        XCTAssertEqual(rig.runner.startedCommandIDs.count, 1,
                       "an already-running listener must not be restarted (it would fight over the port)")
    }

    func testSharePasswordIsReadFromTheCredentialStore() async {
        let rig = makeRig(share: ProxyShare(port: 8888, authEnabled: true, username: "dev"))
        rig.manager.setSharePassword("s3cret")

        rig.manager.startShare()
        await rig.awaitLaunch()

        XCTAssertEqual(rig.controller?.command.command,
                       "/opt/homebrew/bin/gost -L 'auto://dev:s3cret@:8888'")
        // The password is in the Keychain, never in the config file on disk.
        let onDisk = try? String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(onDisk?.contains("s3cret") ?? false)
    }

    // MARK: advertising follows the daemon

    func testAdvertisesWhenTheListenerComesUp() async {
        let rig = makeRig()
        rig.manager.start()   // the persisted toggle is on → start() brings the listener up
        await rig.awaitLaunch()

        rig.controller?.started(pid: 42)
        await yieldUntil { rig.manager.isAdvertising }

        XCTAssertEqual(rig.advertiser.advertised.count, 1)
        let ad = try! XCTUnwrap(rig.advertiser.advertised.first)
        XCTAssertEqual(ad.host, "192.168.1.42", "the announced address is the en* one, not the VPN tunnel")
        XCTAssertEqual(ad.port, 9999)
        XCTAssertFalse(ad.authRequired)
    }

    func testTXTAuthFlagMirrorsTheShareAndCarriesNoPassword() async {
        let rig = makeRig(share: ProxyShare(port: 9999, authEnabled: true, username: "dev"))
        rig.manager.setSharePassword("s3cret")
        rig.manager.startShare()
        await rig.awaitLaunch()
        rig.controller?.started(pid: 42)
        await yieldUntil { rig.manager.isAdvertising }

        let ad = try! XCTUnwrap(rig.advertiser.lastTXT)
        XCTAssertTrue(ad.authRequired)
        let txt = proxyTXTRecord(ad)
        XCTAssertEqual(txt["auth"], "1")
        XCTAssertFalse(txt.values.contains("s3cret"), "the password is never announced")
        XCTAssertFalse(txt.keys.contains { $0.lowercased().contains("pass") })
    }

    func testWithdrawsTheAnnouncementWhenTheListenerDies() async {
        // No watchdog restart in the way: an unsupervised listener that dies must be withdrawn.
        let rig = makeRig()
        rig.manager.startShare()
        await rig.awaitLaunch()
        rig.controller?.started(pid: 42)
        await yieldUntil { rig.manager.isAdvertising }
        rig.processManager.disarmWatchdog(ProxyShare.daemonID)

        rig.controller?.terminate(1)
        await yieldUntil { !rig.manager.isAdvertising }

        XCTAssertEqual(rig.advertiser.stopCount, 1)
        XCTAssertNil(rig.manager.lastExitIP)
    }

    func testAWatchdogRestartReAnnounces() async {
        let rig = makeRig()
        rig.manager.startShare()
        await rig.awaitLaunch()
        rig.controller?.started(pid: 42)
        await yieldUntil { rig.manager.isAdvertising }

        // gost dies; the watchdog (armed by the synthetic command) brings it back on its own.
        // The announcement must follow the listener back up with no extra wiring.
        rig.controller?.terminate(1)
        await sleepUntil { rig.runner.startedCommandIDs.count == 2 }
        rig.controller?.started(pid: 43)
        await yieldUntil { rig.manager.isAdvertising }

        XCTAssertEqual(rig.advertiser.advertised.count, 2, "the restarted listener publishes again")
        XCTAssertEqual(rig.advertiser.stopCount, 1, "…after the dead one was withdrawn")
    }

    func testNoLANAddressMeansNoAnnouncement() async {
        let rig = makeRig(lanIP: nil)
        rig.manager.startShare()
        await rig.awaitLaunch()
        rig.controller?.started(pid: 42)
        await yieldUntil { rig.processManager.states[ProxyShare.daemonID] == .daemonRunning }

        XCTAssertFalse(rig.manager.isAdvertising,
                       "announcing an unreachable address is worse than not announcing at all")
        XCTAssertTrue(rig.advertiser.advertised.isEmpty)
    }

    func testExitIPIsFoldedIntoTheTXTRecord() async {
        let rig = makeRig(exitIP: "78.40.193.132\n")
        rig.manager.startShare()
        await rig.awaitLaunch()
        rig.controller?.started(pid: 42)
        await sleepUntil { rig.manager.lastExitIP != nil }

        XCTAssertEqual(rig.manager.lastExitIP, "78.40.193.132", "trailing newline from curl is trimmed")
        XCTAssertEqual(rig.advertiser.lastTXT?.exitIP, "78.40.193.132")
        XCTAssertEqual(proxyTXTRecord(rig.advertiser.lastTXT!)["vpnip"], "78.40.193.132")
    }

    func testExitIPProbeRetriesWhileGostIsStillBinding() async {
        // Observed for real on 2026-07-25: `.started` fires when gost is SPAWNED, so the first
        // probe gets connection-refused (curl prints nothing) and a single-shot probe gave up
        // silently — `vpnip` never appeared in the TXT record even though the proxy worked.
        let flaky = FlakyExitIPProbe(failures: 2, ip: "78.40.193.132")
        let rig = makeRig(exitIPProbe: { flaky.probe($0) })
        rig.manager.startShare()
        await rig.awaitLaunch()
        rig.controller?.started(pid: 42)

        await sleepUntil { rig.manager.lastExitIP != nil }

        XCTAssertEqual(rig.manager.lastExitIP, "78.40.193.132")
        XCTAssertEqual(proxyTXTRecord(rig.advertiser.lastTXT!)["vpnip"], "78.40.193.132",
                       "the announcement is updated in place once the egress is confirmed")
        XCTAssertEqual(flaky.callCount, 3, "two refusals, then success")
    }

    func testExitIPProbeGivesUpAfterTheAttemptLimit() async {
        let flaky = FlakyExitIPProbe(failures: .max, ip: "unused")
        let rig = makeRig(exitIPProbe: { flaky.probe($0) })
        rig.manager.startShare()
        await rig.awaitLaunch()
        rig.controller?.started(pid: 42)
        await yieldUntil { rig.manager.isAdvertising }
        await sleepUntil { flaky.callCount >= 4 }

        // The share stays announced — an unconfirmed egress must not withdraw a working proxy.
        XCTAssertTrue(rig.manager.isAdvertising)
        XCTAssertNil(rig.manager.lastExitIP)
        XCTAssertNil(proxyTXTRecord(rig.advertiser.lastTXT!)["vpnip"])
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(flaky.callCount, 4, "bounded — it does not probe forever")
    }

    func testStopShareStopsTheListenerAndWithdraws() async {
        let rig = makeRig()
        rig.manager.startShare()
        await rig.awaitLaunch()
        rig.controller?.started(pid: 42)
        await yieldUntil { rig.manager.isAdvertising }

        rig.manager.stopShare()
        await yieldUntil { rig.processManager.states[ProxyShare.daemonID] == .idle }

        XCTAssertFalse(rig.manager.isAdvertising)
        XCTAssertEqual(rig.advertiser.stopCount, 1)
    }

    func testDisabledShareStartsNothingOnLaunch() async {
        let rig = makeRig()
        rig.store.setProxyShareEnabled(false)

        rig.manager.start()
        await settle()

        XCTAssertTrue(rig.runner.startedCommandIDs.isEmpty)
        XCTAssertFalse(rig.manager.isAdvertising)
    }

    /// Brief real-time pause so an (incorrect) asynchronous launch would have surfaced —
    /// needed because "nothing happened" can't be awaited on a condition.
    private func settle() async {
        try? await Task.sleep(for: .milliseconds(60))
    }
}
