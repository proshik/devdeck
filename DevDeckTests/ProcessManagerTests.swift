import XCTest
@testable import DevDeck

@MainActor
final class ProcessManagerTests: XCTestCase {

    private func cmd(name: String = "c", daemon: Bool = false, sudo: Bool = false) -> Command {
        Command(id: UUID(), name: name, command: "echo", isDaemon: daemon, needsSudo: sudo)
    }

    func testCommandSucceeds() async {
        let fake = FakeCommandRunner()
        let c = cmd()
        fake.eagerScripts[c.id] = [.started(pid: 1), .line("ok", stream: .stdout), .terminated(exitCode: 0)]
        let m = ProcessManager(runner: fake)

        m.run(c)
        await yieldUntil { m.states[c.id] == .succeeded }

        XCTAssertEqual(m.states[c.id], .succeeded)
        XCTAssertEqual(m.logs[c.id]?.elements, [LogLine(text: "ok", stream: .stdout)])
    }

    func testCommandFailsPreservesExactCode() async {
        for code in [Int32(2), 130, 137] {
            let fake = FakeCommandRunner()
            let c = cmd()
            fake.eagerScripts[c.id] = [.started(pid: 1), .terminated(exitCode: code)]
            let m = ProcessManager(runner: fake)

            m.run(c)
            await yieldUntil { m.states[c.id] == .failed(code: code) }

            XCTAssertEqual(m.states[c.id], .failed(code: code))
        }
    }

    func testDaemonReachesDaemonRunningAndStays() async {
        let fake = FakeCommandRunner()
        let c = cmd(daemon: true)
        let m = ProcessManager(runner: fake)

        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        ctrl.started(pid: 100)
        await yieldUntil { m.states[c.id] == .daemonRunning }

        XCTAssertEqual(m.states[c.id], .daemonRunning)
        XCTAssertTrue(m.hasLiveDaemons())
        XCTAssertEqual(m.aliveDaemons, [c.id])

        await Task.yield(); await Task.yield()
        XCTAssertEqual(m.states[c.id], .daemonRunning, "daemon stays daemonRunning without termination")
    }

    func testDaemonCleanExitClearsIndicator() async {
        let fake = FakeCommandRunner()
        let c = cmd(daemon: true)
        let m = ProcessManager(runner: fake)

        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        ctrl.started(pid: 100)
        await yieldUntil { m.states[c.id] == .daemonRunning }
        ctrl.terminate(0)
        await yieldUntil { m.states[c.id] == .succeeded }

        XCTAssertFalse(m.hasLiveDaemons())
        XCTAssertFalse(m.aliveDaemons.contains(c.id))
    }

    func testStopInvokesHandleAndDrivesTerminalFromEvent() async {
        let fake = FakeCommandRunner()  // autoTerminateOnStopCode = 143 (dies as SIGTERM)
        let c = cmd()
        let m = ProcessManager(runner: fake)

        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        ctrl.started()
        await yieldUntil { m.states[c.id] == .running }
        m.stop(c.id)
        await yieldUntil { m.states[c.id] == .idle }

        XCTAssertEqual(ctrl.stopCount, 1)
        XCTAssertEqual(m.states[c.id], .idle, "user-initiated stop — neutral state (idle), not shown as failed")
    }

    func testStoppedDaemonShowsIdleNotFailed() async {
        let fake = FakeCommandRunner()   // autoTerminateOnStopCode = 143 (like SIGTERM)
        let c = cmd(daemon: true)
        let m = ProcessManager(runner: fake)

        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        ctrl.started(pid: 1)
        await yieldUntil { m.states[c.id] == .daemonRunning }
        m.stop(c.id)
        await yieldUntil { m.states[c.id] == .idle }

        XCTAssertEqual(m.states[c.id], .idle, "stopped daemon — neutral state, not shown as failed")
        XCTAssertFalse(m.hasLiveDaemons())
    }

    func testCrashedCommandStillShowsFailed() async {
        // A natural crash (NOT a user-initiated stop) stays as failed.
        let fake = FakeCommandRunner()
        let c = cmd()
        fake.eagerScripts[c.id] = [.started(pid: 1), .terminated(exitCode: 2)]
        let m = ProcessManager(runner: fake)

        m.run(c)
        await yieldUntil { m.states[c.id] == .failed(code: 2) }

        XCTAssertEqual(m.states[c.id], .failed(code: 2))
    }

    func testStopOnIdleIsNoOp() {
        let fake = FakeCommandRunner()
        let m = ProcessManager(runner: fake)
        m.stop(UUID())
        XCTAssertTrue(m.states.isEmpty)
    }

    func testIdempotentStopAfterTermination() async {
        let fake = FakeCommandRunner()
        let c = cmd()
        fake.eagerScripts[c.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        let m = ProcessManager(runner: fake)

        m.run(c)
        await yieldUntil { m.states[c.id] == .succeeded }
        m.stop(c.id)   // active[id] == nil → safe no-op

        XCTAssertEqual(m.states[c.id], .succeeded)
    }

    func testSudoDaemonRejected() {
        let fake = FakeCommandRunner()
        let c = cmd(daemon: true, sudo: true)
        let m = ProcessManager(runner: fake)

        m.run(c)

        XCTAssertEqual(m.states[c.id], .failed(code: -1))
        XCTAssertTrue(fake.startedCommandIDs.isEmpty, "runner must not be invoked for a sudo daemon")
    }

    func testRerunSupersedesAndGuardsLateEvent() async {
        let fake = FakeCommandRunner()
        fake.autoTerminateOnStopCode = nil   // old run terminated manually
        let c = cmd()
        let m = ProcessManager(runner: fake)

        m.run(c)
        let c1 = try! XCTUnwrap(fake.controller(for: c.id))
        c1.started()
        await yieldUntil { m.states[c.id] == .running }

        m.run(c)   // re-run PREEMPTS the previous one
        let c2 = try! XCTUnwrap(fake.controller(for: c.id))
        XCTAssertNotEqual(c1.token, c2.token)
        XCTAssertEqual(c1.stopCount, 1, "old handle was stopped")
        c2.started()
        await yieldUntil { m.states[c.id] == .running }

        c1.terminate(99)   // late event from the preempted run
        await Task.yield(); await Task.yield()

        XCTAssertEqual(m.states[c.id], .running, "late event from the old run is ignored (token guard)")
    }
}
