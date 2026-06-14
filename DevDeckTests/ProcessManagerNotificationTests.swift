import XCTest
@testable import DevDeck

@MainActor
final class ProcessManagerNotificationTests: XCTestCase {

    private func cmd(name: String = "c", daemon: Bool = false) -> Command {
        Command(id: UUID(), name: name, command: "echo", isDaemon: daemon)
    }

    // MARK: daemons

    func testDaemonStartNotifies() async {
        let fake = FakeCommandRunner()
        let notifier = FakeNotifier()
        let c = cmd(name: "port-forward", daemon: true)
        let m = ProcessManager(runner: fake, notifier: notifier)

        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        ctrl.started(pid: 100)
        await yieldUntil { m.states[c.id] == .daemonRunning }

        XCTAssertEqual(notifier.posted, [.daemonStarted(name: "port-forward")])
    }

    func testDaemonDiesOnItsOwnNotifiesStopped() async {
        let fake = FakeCommandRunner()
        let notifier = FakeNotifier()
        let c = cmd(name: "pf", daemon: true)
        let m = ProcessManager(runner: fake, notifier: notifier)

        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        ctrl.started(pid: 100)
        await yieldUntil { m.states[c.id] == .daemonRunning }
        ctrl.terminate(1)   // died on its own
        await yieldUntil { m.states[c.id] == .failed(code: 1) }

        XCTAssertEqual(notifier.posted, [
            .daemonStarted(name: "pf"),
            .daemonStopped(name: "pf", code: 1),
        ])
    }

    func testDaemonCleanExitStillNotifiesStopped() async {
        // even a clean exit (code 0) of a daemon counts as "dropped" — we notify
        let fake = FakeCommandRunner()
        let notifier = FakeNotifier()
        let c = cmd(name: "pf", daemon: true)
        let m = ProcessManager(runner: fake, notifier: notifier)

        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        ctrl.started(pid: 1)
        await yieldUntil { m.states[c.id] == .daemonRunning }
        ctrl.terminate(0)
        await yieldUntil { m.states[c.id] == .succeeded }

        XCTAssertEqual(notifier.posted, [
            .daemonStarted(name: "pf"),
            .daemonStopped(name: "pf", code: 0),
        ])
    }

    func testManualDaemonStopIsSilent() async {
        let fake = FakeCommandRunner()   // autoTerminateOnStopCode = 143 (manual stop)
        let notifier = FakeNotifier()
        let c = cmd(name: "pf", daemon: true)
        let m = ProcessManager(runner: fake, notifier: notifier)

        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        ctrl.started(pid: 1)
        await yieldUntil { m.states[c.id] == .daemonRunning }
        m.stop(c.id)
        await yieldUntil { m.states[c.id] == .idle }

        XCTAssertEqual(notifier.posted, [.daemonStarted(name: "pf")], "manual daemon stop — no notification about it dropping")
    }

    func testDaemonFailsToStartNotifies() async {
        let fake = FakeCommandRunner()
        let notifier = FakeNotifier()
        let c = cmd(name: "pf", daemon: true)
        fake.eagerScripts[c.id] = [.terminated(exitCode: 1)]   // died before reaching started
        let m = ProcessManager(runner: fake, notifier: notifier)

        m.run(c)
        await yieldUntil { m.states[c.id] == .failed(code: 1) }

        XCTAssertEqual(notifier.posted, [.daemonFailedToStart(name: "pf", code: 1)])
    }

    func testRerunDoesNotEmitSpuriousDaemonStopped() async {
        // Re-running preempts the previous daemon run. The terminal of the preempted
        // run is suppressed by the token guard → no spurious "stopped" notification should fire.
        let fake = FakeCommandRunner()
        let notifier = FakeNotifier()
        let c = cmd(name: "pf", daemon: true)
        let m = ProcessManager(runner: fake, notifier: notifier)

        m.run(c)
        let ctrl1 = try! XCTUnwrap(fake.controller(for: c.id))
        ctrl1.started(pid: 1)
        await yieldUntil { m.states[c.id] == .daemonRunning }

        m.run(c)   // preempts the first run (old.stop() → terminated(143) on the old stream)
        await yieldUntil { fake.startedCommandIDs.filter { $0 == c.id }.count == 2 }
        let ctrl2 = try! XCTUnwrap(fake.controller(for: c.id))
        ctrl2.started(pid: 2)
        await yieldUntil { m.states[c.id] == .daemonRunning }

        XCTAssertEqual(notifier.posted, [.daemonStarted(name: "pf"), .daemonStarted(name: "pf")],
                       "exactly two starts; the terminal of the preempted run does not send 'stopped'")
    }

    // MARK: regular commands

    func testCommandFailureNotifies() async {
        let fake = FakeCommandRunner()
        let notifier = FakeNotifier()
        let c = cmd(name: "build")
        fake.eagerScripts[c.id] = [.started(pid: 1), .terminated(exitCode: 2)]
        let m = ProcessManager(runner: fake, notifier: notifier)

        m.run(c)
        await yieldUntil { m.states[c.id] == .failed(code: 2) }

        XCTAssertEqual(notifier.posted, [.commandFailed(name: "build", code: 2)])
    }

    func testCommandSuccessIsSilent() async {
        let fake = FakeCommandRunner()
        let notifier = FakeNotifier()
        let c = cmd(name: "build")
        fake.eagerScripts[c.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        let m = ProcessManager(runner: fake, notifier: notifier)

        m.run(c)
        await yieldUntil { m.states[c.id] == .succeeded }

        XCTAssertTrue(notifier.posted.isEmpty, "successful command — silently, no notification")
    }

    func testManualCommandStopIsSilent() async {
        let fake = FakeCommandRunner()
        let notifier = FakeNotifier()
        let c = cmd(name: "build")
        let m = ProcessManager(runner: fake, notifier: notifier)

        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        ctrl.started(pid: 1)
        await yieldUntil { m.states[c.id] == .running }
        m.stop(c.id)
        await yieldUntil { m.states[c.id] == .idle }

        XCTAssertTrue(notifier.posted.isEmpty, "manual command stop — silently, no notification")
    }
}
