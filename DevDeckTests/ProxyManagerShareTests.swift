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
        /// The generated gost config — where the credentials live now that the command line is clean.
        let shareConfig: FakePrivateFile

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
        share: ProxyShare = ProxyShare(port: 9999),
        clientMonitor: ProxyClientMonitor = ProxyClientMonitor()
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
        let shareConfig = FakePrivateFile(url: URL(fileURLWithPath: "/fake/gost.json"))
        let manager = ProxyManager(
            discovering: FakeProxyDiscovering(),
            advertiser: advertiser,
            credentials: credentials,
            lanIP: { lanIP },
            gostPath: { _ in gostInstalled ? "/opt/homebrew/bin/gost" : nil },
            exitIPProbe: exitIPProbe ?? { _ in exitIP },
            exitIPRetryDelay: .milliseconds(1),   // the retry loop is exercised, not waited on
            envFile: FakePrivateFile(),
            shareConfigFile: shareConfig,
            clientMonitor: clientMonitor
        )
        manager.store = store
        manager.processManager = processManager
        return Rig(manager: manager, store: store, processManager: processManager,
                   runner: runner, advertiser: advertiser, credentials: credentials,
                   shareConfig: shareConfig)
    }

    // MARK: starting the listener

    func testStartShareLaunchesTheSyntheticDaemon() async {
        let rig = makeRig()

        rig.manager.startShare()
        await rig.awaitLaunch()

        XCTAssertEqual(rig.runner.startedCommandIDs, [ProxyShare.daemonID])
        XCTAssertFalse(rig.manager.gostMissing)
        let started = rig.controller?.command
        XCTAssertEqual(started?.command, "'/opt/homebrew/bin/gost' -C '/fake/gost.json'")
        XCTAssertTrue(started?.watchdogEnabled == true)
    }

    func testTheConfigIsOnDiskBeforeTheListenerIsLaunched() async {
        let rig = makeRig()

        rig.manager.startShare()
        await rig.awaitLaunch()

        XCTAssertEqual(rig.shareConfig.contents, ProxyShare(port: 9999).gostConfigJSON(password: nil),
                       "gost -C reads the file at startup — writing it after the launch would race")
    }

    func testAnUnwritableConfigStopsTheLaunch() async {
        // `gost -C` on a missing file exits immediately, so launching anyway would just hand the
        // watchdog a restart loop with no way to succeed.
        let rig = makeRig()
        rig.shareConfig.writeSucceeds = false

        rig.manager.startShare()
        await settle()

        XCTAssertTrue(rig.runner.startedCommandIDs.isEmpty)
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

        // The password reaches gost through the 0600 config file, never through the argv every
        // local account can read.
        XCTAssertEqual(rig.controller?.command.command, "'/opt/homebrew/bin/gost' -C '/fake/gost.json'")
        XCTAssertEqual(rig.shareConfig.contents?.contains(#""password":"s3cret""#), true)
        XCTAssertEqual(rig.shareConfig.contents?.contains(#""username":"dev""#), true)
        // And still never into config.json.
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

    /// Mutable clock for the connected-clients monitor — same idea as `ProxyClientMonitorTests`'
    /// `TestClock`, needed here too so the retention window can be crossed without a real-time wait.
    private final class ShareTestClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private func gostOpenLine(_ client: String, sid: String) -> String {
        """
        {"client":"\(client)","kind":"handler","level":"info","local":"192.168.1.42:9999",\
        "msg":"\(client) <> 192.168.1.42:9999","service":"devdeck-proxy","sid":"\(sid)"}
        """
    }

    /// Regression for the connected-clients monitor: `listenerDidStart()` used to be called only
    /// from inside `startAdvertising()`, which returns early right here — with no LAN address at
    /// all — before ever reaching it. That left two real bugs: a watchdog restart never zeroed the
    /// live sessions a dead process left behind, and the sweep was never armed for the whole
    /// session, so retention silently became infinite. Both must now follow the LISTENER's own
    /// state, not whether Bonjour actually announced it.
    func testListenerReachingDaemonRunningResetsSessionsAndArmsTheSweepEvenWithoutLAN() async {
        let clock = ShareTestClock()
        // publishInterval stays real-time-coalesced (the default) — `publishNow()` below drives the
        // two deterministic checkpoints directly, the same way `ProxyClientMonitorTests` does, so
        // only the thing this test actually needs real elapsed time for — the sweep's own repeating
        // timer — depends on wall-clock time at all.
        let monitor = ProxyClientMonitor(now: { clock.now }, retention: 5, sweepInterval: .milliseconds(20))
        let rig = makeRig(lanIP: nil, clientMonitor: monitor)

        rig.manager.startShare()
        await rig.awaitLaunch()
        rig.controller?.started(pid: 42)
        await yieldUntil { rig.processManager.states[ProxyShare.daemonID] == .daemonRunning }
        XCTAssertFalse(rig.manager.isAdvertising, "sanity: no LAN address means no announcement")

        // A session left open — standing in for whatever gost's own state was the moment it died.
        rig.manager.ingestDaemonOutput(ProxyShare.daemonID, gostOpenLine("192.168.1.99:1000", sid: "a"))
        monitor.publishNow()
        XCTAssertEqual(monitor.clients.first?.liveSessions, 1, "sanity: the session was recorded")

        // The watchdog brings gost back. `isAdvertising` never turns on anywhere in this test — the
        // old code, which reset sessions and armed the sweep only from inside `startAdvertising()`,
        // would never run either step at all.
        rig.controller?.terminate(1)
        await sleepUntil { rig.runner.startedCommandIDs.count == 2 }
        rig.controller?.started(pid: 43)
        await yieldUntil { rig.processManager.states[ProxyShare.daemonID] == .daemonRunning }

        monitor.publishNow()
        XCTAssertEqual(monitor.clients.first?.liveSessions, 0,
                       "the dead process's session was never reset without a LAN address")

        // The sweep must be armed too: past the retention window the entry prunes on its own, with
        // no `sweepNow()` call anywhere in this test — proving the automatic timer, not just the
        // pruning logic `ProxyClientMonitorTests` already covers directly.
        clock.advance(6)
        await sleepUntil({ monitor.clients.isEmpty },
                         message: "the sweep was never armed without a LAN address")
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
        XCTAssertNil(rig.shareConfig.contents,
                     "the password should not outlive the listener that needed it")
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
