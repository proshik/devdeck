import XCTest
@testable import DevDeck

/// Port-conflict flow: the proactive pre-check before launching a daemon, the reactive
/// check after a fast failure, "Kill & start" with SIGKILL escalation, and the watchdog
/// pausing instead of burning retries on an occupied port.
@MainActor
final class ProcessManagerPortConflictTests: XCTestCase {

    private static let fastPolicy = SupervisionPolicy(
        restartDelays: [.milliseconds(40), .milliseconds(40), .milliseconds(40)],
        stabilityWindow: .milliseconds(150),
        adoptedPollInterval: .milliseconds(30),
        portFreePollInterval: .milliseconds(10),
        portFreeTimeout: .milliseconds(100)
    )

    private func daemon(watchdog: Bool = false) -> Command {
        Command(id: UUID(), name: "pf", command: "kubectl port-forward svc/x 8080:80",
                isDaemon: true, watchdogEnabled: watchdog, port: 8080)
    }

    private func makeManager(
        runner: FakeCommandRunner,
        inspector: FakePortInspector,
        reaper: FakeDaemonReaper? = nil
    ) -> ProcessManager {
        ProcessManager(runner: runner, notifier: FakeNotifier(), reaper: reaper ?? FakeDaemonReaper(),
                       portInspector: inspector, policy: Self.fastPolicy)
    }

    func testProactiveCheckBlocksStartWhenPortOccupied() async {
        let fake = FakeCommandRunner()
        let inspector = FakePortInspector()
        inspector.occupants[8080] = PortOccupant(pid: 555, processName: "python3")
        let c = daemon()
        let m = makeManager(runner: fake, inspector: inspector)

        m.run(c)

        await sleepUntil { m.portConflicts[c.id] != nil }
        XCTAssertTrue(fake.startedCommandIDs.isEmpty, "occupied port — the daemon must not start")
        XCTAssertEqual(m.states[c.id], .idle)
        XCTAssertEqual(m.portConflicts[c.id]?.port, 8080)
        XCTAssertEqual(m.portConflicts[c.id]?.occupant, PortOccupant(pid: 555, processName: "python3"))
    }

    func testProactiveCheckLaunchesWhenPortFree() async {
        let fake = FakeCommandRunner()
        let inspector = FakePortInspector()
        let c = daemon()
        let m = makeManager(runner: fake, inspector: inspector)

        m.run(c)

        await sleepUntil { fake.startedCommandIDs.count == 1 }
        XCTAssertEqual(inspector.queriedPorts, [8080], "the pre-check actually ran")
        XCTAssertNil(m.portConflicts[c.id])
    }

    func testKillAndStartFreesPortAndLaunches() async {
        let fake = FakeCommandRunner()
        let inspector = FakePortInspector()
        let reaper = FakeDaemonReaper()
        inspector.occupants[8080] = PortOccupant(pid: 555, processName: "python3")
        let c = daemon()
        let m = makeManager(runner: fake, inspector: inspector, reaper: reaper)

        m.run(c)
        await sleepUntil { m.portConflicts[c.id] != nil }

        m.killOccupantAndStart(c.id)
        inspector.occupants = [:]   // SIGTERM worked — the port is free

        await sleepUntil { fake.startedCommandIDs.count == 1 }
        XCTAssertEqual(reaper.killed, [555])
        XCTAssertTrue(reaper.forceKilled.isEmpty, "no escalation when SIGTERM is enough")
        XCTAssertNil(m.portConflicts[c.id], "conflict cleared after a successful start")
    }

    func testKillAndStartEscalatesToSigkillWhenPortStaysBusy() async {
        let fake = FakeCommandRunner()
        let inspector = FakePortInspector()
        let reaper = FakeDaemonReaper()
        inspector.occupants[8080] = PortOccupant(pid: 555, processName: "python3")
        let c = daemon()
        let m = makeManager(runner: fake, inspector: inspector, reaper: reaper)

        m.run(c)
        await sleepUntil { m.portConflicts[c.id] != nil }

        m.killOccupantAndStart(c.id)   // the occupant ignores SIGTERM (port stays busy)

        await sleepUntil { reaper.forceKilled == [555] }
        inspector.occupants = [:]      // SIGKILL worked
        await sleepUntil { fake.startedCommandIDs.count == 1 }
        XCTAssertNil(m.portConflicts[c.id])
    }

    func testReactiveDetectionAfterFastFailure() async {
        let fake = FakeCommandRunner()
        let inspector = FakePortInspector()
        let c = daemon()
        let m = makeManager(runner: fake, inspector: inspector)

        m.run(c)   // port free at pre-check time
        await sleepUntil { fake.startedCommandIDs.count == 1 }

        inspector.occupants[8080] = PortOccupant(pid: 777, processName: "kubectl")
        fake.controller(for: c.id)!.terminate(1)   // dies before .started — "failed to start"

        await sleepUntil { m.portConflicts[c.id] != nil }
        XCTAssertEqual(m.states[c.id], .failed(code: 1), "the row stays red; the panel appears under it")
        XCTAssertEqual(m.portConflicts[c.id]?.occupant.pid, 777)
    }

    func testWatchdogPausesOnConflictInsteadOfBurningRetries() async {
        let fake = FakeCommandRunner()
        let inspector = FakePortInspector()
        let reaper = FakeDaemonReaper()
        let c = daemon(watchdog: true)
        let m = makeManager(runner: fake, inspector: inspector, reaper: reaper)

        m.run(c)
        await sleepUntil { fake.startedCommandIDs.count == 1 }
        fake.controller(for: c.id)!.started(pid: 1)
        await yieldUntil { m.states[c.id] == .daemonRunning }

        inspector.occupants[8080] = PortOccupant(pid: 555, processName: "python3")
        fake.controller(for: c.id)!.terminate(1)   // died; the restart gate must hit the occupant

        await sleepUntil { m.watchdogPhases[c.id] == .pausedOnConflict }
        XCTAssertEqual(fake.startedCommandIDs.count, 1, "no restart attempts against an occupied port")
        XCTAssertNotNil(m.portConflicts[c.id])

        m.killOccupantAndStart(c.id)
        inspector.occupants = [:]
        await sleepUntil { fake.startedCommandIDs.count == 2 }
        XCTAssertEqual(m.watchdogPhases[c.id], .armed, "watchdog resumes after the conflict is resolved")
    }

    func testDismissConflictClearsPanelAndPausedWatchdog() async {
        let fake = FakeCommandRunner()
        let inspector = FakePortInspector()
        inspector.occupants[8080] = PortOccupant(pid: 555, processName: "python3")
        let c = daemon(watchdog: true)
        let m = makeManager(runner: fake, inspector: inspector)

        m.run(c)
        await sleepUntil { m.portConflicts[c.id] != nil }

        m.dismissPortConflict(c.id)
        XCTAssertNil(m.portConflicts[c.id])
        XCTAssertNil(m.watchdogPhases[c.id], "paused watchdog is cleared until the next manual start")
        XCTAssertTrue(fake.startedCommandIDs.isEmpty)
    }
}
