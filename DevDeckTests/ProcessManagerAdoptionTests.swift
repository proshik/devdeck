import XCTest
@testable import DevDeck

@MainActor
final class ProcessManagerAdoptionTests: XCTestCase {

    private func daemon(id: UUID = UUID(), name: String = "pf") -> Command {
        Command(id: id, name: name, command: "kubectl port-forward svc/foo 30090:8080", isDaemon: true)
    }

    // MARK: adoption on startup (finding an orphaned process by command string)

    func testAdoptsSurvivingOrphan() {
        let reaper = FakeDaemonReaper()
        let notifier = FakeNotifier()
        let c = daemon()
        reaper.orphanByCommand[c.command] = 9001
        let m = ProcessManager(runner: FakeCommandRunner(), notifier: notifier, reaper: reaper)

        m.adoptSurvivingDaemons(commands: [c.id: c])

        XCTAssertEqual(m.states[c.id], .daemonRunning)
        XCTAssertTrue(m.hasLiveDaemons())
        XCTAssertEqual(m.aliveDaemons, [c.id])
        XCTAssertEqual(notifier.posted, [.daemonAdopted(name: "pf")])
    }

    func testNoOrphanNothingAdopted() {
        let reaper = FakeDaemonReaper()   // orphanByCommand is empty → no orphans
        let notifier = FakeNotifier()
        let c = daemon()
        let m = ProcessManager(runner: FakeCommandRunner(), notifier: notifier, reaper: reaper)

        m.adoptSurvivingDaemons(commands: [c.id: c])

        XCTAssertNil(m.states[c.id])
        XCTAssertFalse(m.hasLiveDaemons())
        XCTAssertTrue(notifier.posted.isEmpty)
    }

    func testNonDaemonCommandsIgnored() {
        let reaper = FakeDaemonReaper()
        let c = Command(id: UUID(), name: "build", command: "just build", isDaemon: false)
        reaper.orphanByCommand[c.command] = 9001   // even if matched — it's not a daemon
        let m = ProcessManager(runner: FakeCommandRunner(), reaper: reaper)

        m.adoptSurvivingDaemons(commands: [c.id: c])

        XCTAssertNil(m.states[c.id])
    }

    // MARK: stopping an adopted daemon

    func testStopAdoptedDaemonKillsTreeAndFreesState() {
        let reaper = FakeDaemonReaper()
        let c = daemon()
        reaper.orphanByCommand[c.command] = 9001
        let m = ProcessManager(runner: FakeCommandRunner(), reaper: reaper)
        m.adoptSurvivingDaemons(commands: [c.id: c])

        m.stop(c.id)

        XCTAssertEqual(reaper.killed, [9001], "stopping an adopted daemon kills the PID subtree")
        XCTAssertEqual(m.states[c.id], .idle)
        XCTAssertFalse(m.hasLiveDaemons())
    }

    func testRerunOverAdoptedKillsOldFirst() async {
        // Re-running (e.g. a chain step) on top of an adopted daemon kills the old
        // process; subsequent control goes through the new run (not by PID).
        let fake = FakeCommandRunner()
        let reaper = FakeDaemonReaper()
        let c = daemon()
        reaper.orphanByCommand[c.command] = 9001
        let m = ProcessManager(runner: fake, reaper: reaper)
        m.adoptSurvivingDaemons(commands: [c.id: c])
        XCTAssertEqual(m.states[c.id], .daemonRunning)

        m.run(c)
        XCTAssertEqual(reaper.killed, [9001], "adopted process is killed before starting a new run")

        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        ctrl.started(pid: 5555)
        await yieldUntil { m.states[c.id] == .daemonRunning }

        m.stop(c.id)   // stop now goes through the handle normally, not by the old PID
        await yieldUntil { m.states[c.id] == .idle }

        XCTAssertEqual(reaper.killed, [9001], "reaper is not called again — the new run stops normally")
        XCTAssertEqual(ctrl.stopCount, 1)
    }

    func testAdoptedDaemonCountsForExitDialog() {
        // An adopted daemon must be counted by the quit dialog (aliveDaemons).
        let reaper = FakeDaemonReaper()
        let c = daemon()
        reaper.orphanByCommand[c.command] = 9001
        let m = ProcessManager(runner: FakeCommandRunner(), reaper: reaper)

        m.adoptSurvivingDaemons(commands: [c.id: c])

        XCTAssertTrue(m.hasLiveDaemons())
        XCTAssertEqual(m.aliveDaemons, [c.id])
    }
}
