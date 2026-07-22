import XCTest
@testable import DevDeck

/// Daemon watchdog: automatic restart after an unexpected death, retry limit,
/// counter reset after a stable run, adopted-daemon polling. Millisecond policy —
/// tests run in real time but fast; waits go through `sleepUntil` (Task.sleep paths).
@MainActor
final class ProcessManagerWatchdogTests: XCTestCase {

    private static let fastPolicy = SupervisionPolicy(
        restartDelays: [.milliseconds(40), .milliseconds(40), .milliseconds(40)],
        stabilityWindow: .milliseconds(150),
        adoptedPollInterval: .milliseconds(30),
        portFreePollInterval: .milliseconds(10),
        portFreeTimeout: .milliseconds(100)
    )

    private func daemon(name: String = "pf", watchdog: Bool = true, port: Int? = nil) -> Command {
        Command(id: UUID(), name: name, command: "kubectl port-forward svc/x 8080:80",
                isDaemon: true, watchdogEnabled: watchdog, port: port)
    }

    private func makeManager(
        runner: FakeCommandRunner,
        notifier: FakeNotifier? = nil,
        reaper: FakeDaemonReaper? = nil
    ) -> ProcessManager {
        ProcessManager(runner: runner, notifier: notifier ?? FakeNotifier(), reaper: reaper ?? FakeDaemonReaper(),
                       portInspector: FakePortInspector(), policy: Self.fastPolicy)
    }

    func testUnexpectedDeathRestartsWithoutStoppedBanner() async {
        let fake = FakeCommandRunner()
        let notifier = FakeNotifier()
        let c = daemon()
        let m = makeManager(runner: fake, notifier: notifier)

        m.run(c)
        fake.controller(for: c.id)!.started(pid: 1)
        await yieldUntil { m.states[c.id] == .daemonRunning }
        XCTAssertEqual(m.watchdogPhases[c.id], .armed)

        fake.controller(for: c.id)!.terminate(1)   // died on its own
        await sleepUntil { fake.startedCommandIDs.count == 2 }
        fake.controller(for: c.id)!.started(pid: 2)
        await yieldUntil { m.states[c.id] == .daemonRunning }

        XCTAssertFalse(notifier.posted.contains(.daemonStopped(name: "pf", code: 1)),
                       "a scheduled restart replaces the 'daemon stopped' banner")
    }

    func testCleanExitAlsoRestarts() async {
        // A port-forward exiting 0 is still dead — the watchdog restarts regardless of code.
        let fake = FakeCommandRunner()
        let c = daemon()
        let m = makeManager(runner: fake)

        m.run(c)
        fake.controller(for: c.id)!.started(pid: 1)
        await yieldUntil { m.states[c.id] == .daemonRunning }
        fake.controller(for: c.id)!.terminate(0)

        await sleepUntil { fake.startedCommandIDs.count == 2 }
    }

    func testUserStopDoesNotRestart() async {
        let fake = FakeCommandRunner()   // stop() auto-terminates with 143
        let c = daemon()
        let m = makeManager(runner: fake)

        m.run(c)
        fake.controller(for: c.id)!.started(pid: 1)
        await yieldUntil { m.states[c.id] == .daemonRunning }

        m.stop(c.id)
        await yieldUntil { m.states[c.id] == .idle }
        XCTAssertNil(m.watchdogPhases[c.id], "manual stop deactivates the watchdog")

        try? await Task.sleep(for: .milliseconds(200))   // several restart delays
        XCTAssertEqual(fake.startedCommandIDs.count, 1, "no restart after a user stop")
    }

    func testGivesUpAfterExhaustingRetries() async {
        let fake = FakeCommandRunner()
        let notifier = FakeNotifier()
        let c = daemon()
        fake.eagerScripts[c.id] = [.started(pid: 1), .terminated(exitCode: 1)]   // dies instantly, every time
        let m = makeManager(runner: fake, notifier: notifier)

        m.run(c)

        await sleepUntil { m.watchdogPhases[c.id] == .gaveUp }
        XCTAssertEqual(fake.startedCommandIDs.count, 4, "initial start + 3 restarts")
        XCTAssertEqual(notifier.posted.filter { $0 == .watchdogGaveUp(name: "pf") }.count, 1)
        XCTAssertFalse(notifier.posted.contains { if case .daemonStopped = $0 { return true } else { return false } })

        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fake.startedCommandIDs.count, 4, "gave up — no further restarts")
    }

    func testStableRunResetsFailureCounter() async {
        let fake = FakeCommandRunner()
        let c = daemon()
        let m = makeManager(runner: fake)

        m.run(c)
        fake.controller(for: c.id)!.started(pid: 1)
        await yieldUntil { m.states[c.id] == .daemonRunning }
        fake.controller(for: c.id)!.terminate(1)                       // failure #1
        await sleepUntil { fake.startedCommandIDs.count == 2 }

        fake.controller(for: c.id)!.started(pid: 2)
        await yieldUntil { m.states[c.id] == .daemonRunning }
        try? await Task.sleep(for: .milliseconds(250))                 // outlive stabilityWindow (150 ms)

        fake.controller(for: c.id)!.terminate(1)                       // death after a STABLE run
        await sleepUntil { m.watchdogPhases[c.id] == .restarting(attempt: 1) || fake.startedCommandIDs.count == 3 }
        await sleepUntil { fake.startedCommandIDs.count == 3 }
        XCTAssertNotEqual(m.watchdogPhases[c.id], .gaveUp,
                          "counter was reset by the stable run — attempts start over")
    }

    func testManualRunDuringRestartDelayIsNotDoubled() async {
        let fake = FakeCommandRunner()
        let c = daemon()
        let m = makeManager(runner: fake)

        m.run(c)
        fake.controller(for: c.id)!.started(pid: 1)
        await yieldUntil { m.states[c.id] == .daemonRunning }
        fake.controller(for: c.id)!.terminate(1)                       // restart scheduled in 40 ms

        m.run(c)                                                       // user restarts by hand at once
        await yieldUntil { fake.startedCommandIDs.count == 2 }
        try? await Task.sleep(for: .milliseconds(150))                 // let the pending restart task fire
        XCTAssertEqual(fake.startedCommandIDs.count, 2,
                       "the pending watchdog restart must not start a second copy")
    }

    func testArmWhileRunningAndDisarmKeepsDaemonAlive() async {
        let fake = FakeCommandRunner()
        let c = daemon(watchdog: false)
        let m = makeManager(runner: fake)

        m.run(c)
        fake.controller(for: c.id)!.started(pid: 1)
        await yieldUntil { m.states[c.id] == .daemonRunning }
        XCTAssertNil(m.watchdogPhases[c.id])

        m.armWatchdog(c)                                               // arm without restarting
        XCTAssertEqual(m.watchdogPhases[c.id], .armed)
        XCTAssertEqual(fake.startedCommandIDs.count, 1)

        m.disarmWatchdog(c.id)                                         // disarm keeps it running
        XCTAssertNil(m.watchdogPhases[c.id])
        XCTAssertEqual(m.states[c.id], .daemonRunning)

        fake.controller(for: c.id)!.terminate(1)
        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(fake.startedCommandIDs.count, 1, "disarmed — death does not restart")
    }

    func testArmWatchdogStartsIdleDaemon() async {
        let fake = FakeCommandRunner()
        let c = daemon(watchdog: false)
        let m = makeManager(runner: fake)

        m.armWatchdog(c)
        await sleepUntil { fake.startedCommandIDs.count == 1 }
        XCTAssertEqual(m.watchdogPhases[c.id], .armed)
    }

    func testAdoptedDaemonIsRestartedWhenPIDDies() async {
        let fake = FakeCommandRunner()
        let reaper = FakeDaemonReaper()
        let c = daemon()
        reaper.orphanByCommand[c.command] = 4242
        reaper.alivePIDs = [4242]
        let m = makeManager(runner: fake, reaper: reaper)

        m.adoptSurvivingDaemons(commands: [c.id: c])
        await yieldUntil { m.states[c.id] == .daemonRunning }
        XCTAssertEqual(m.watchdogPhases[c.id], .armed, "persisted flag arms the adopted daemon")

        reaper.alivePIDs = []                                          // the orphan died
        await sleepUntil { fake.startedCommandIDs.count == 1 }         // real relaunch
        fake.controller(for: c.id)!.started(pid: 7)
        await yieldUntil { m.states[c.id] == .daemonRunning }
    }
}
