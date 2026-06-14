import XCTest
@testable import DevDeck

@MainActor
final class ProcessManagerChainTests: XCTestCase {

    private func cmd(_ name: String, daemon: Bool = false, sudo: Bool = false) -> Command {
        Command(id: UUID(), name: name, command: "echo \(name)", isDaemon: daemon, needsSudo: sudo)
    }

    private func map(_ commands: [Command]) -> [UUID: Command] {
        Dictionary(uniqueKeysWithValues: commands.map { ($0.id, $0) })
    }

    func testChainHappyPathSequential() async {
        let fake = FakeCommandRunner()
        let c0 = cmd("a"), c1 = cmd("b"), c2 = cmd("c")
        let chain = Chain(id: UUID(), name: "seq", commandIDs: [c0.id, c1.id, c2.id], stopOnError: true)
        let m = ProcessManager(runner: fake)

        m.run(chain, commands: map([c0, c1, c2]))
        await yieldUntil { fake.startedCommandIDs == [c0.id] }
        XCTAssertEqual(fake.startedCommandIDs, [c0.id], "the next step does not start until the previous one succeeds")

        try! XCTUnwrap(fake.controller(for: c0.id)).terminate(0)
        await yieldUntil { fake.startedCommandIDs == [c0.id, c1.id] }

        try! XCTUnwrap(fake.controller(for: c1.id)).terminate(0)
        await yieldUntil { fake.startedCommandIDs == [c0.id, c1.id, c2.id] }

        try! XCTUnwrap(fake.controller(for: c2.id)).terminate(0)
        await yieldUntil { m.chainStates[chain.id] == .succeeded }

        XCTAssertEqual(fake.startedCommandIDs, [c0.id, c1.id, c2.id])
    }

    func testChainStopOnErrorHaltsBeforeNextStep() async {
        let fake = FakeCommandRunner()
        let c0 = cmd("a"), c1 = cmd("b"), c2 = cmd("c")
        let chain = Chain(id: UUID(), name: "seq", commandIDs: [c0.id, c1.id, c2.id], stopOnError: true)
        let m = ProcessManager(runner: fake)

        m.run(chain, commands: map([c0, c1, c2]))
        await yieldUntil { fake.startedCommandIDs == [c0.id] }
        try! XCTUnwrap(fake.controller(for: c0.id)).terminate(0)
        await yieldUntil { fake.startedCommandIDs == [c0.id, c1.id] }
        try! XCTUnwrap(fake.controller(for: c1.id)).terminate(2)
        await yieldUntil { m.chainStates[chain.id] == .failed(atIndex: 1, code: 2) }

        XCTAssertEqual(m.states[c1.id], .failed(code: 2), "the failed step is highlighted")
        XCTAssertEqual(fake.startedCommandIDs, [c0.id, c1.id], "step 2 did NOT start")
    }

    func testChainContinuesWhenStopOnErrorFalse() async {
        let fake = FakeCommandRunner()
        let c0 = cmd("a"), c1 = cmd("b"), c2 = cmd("c")
        let chain = Chain(id: UUID(), name: "seq", commandIDs: [c0.id, c1.id, c2.id], stopOnError: false)
        let m = ProcessManager(runner: fake)

        m.run(chain, commands: map([c0, c1, c2]))
        await yieldUntil { fake.startedCommandIDs == [c0.id] }
        try! XCTUnwrap(fake.controller(for: c0.id)).terminate(0)
        await yieldUntil { fake.startedCommandIDs == [c0.id, c1.id] }
        try! XCTUnwrap(fake.controller(for: c1.id)).terminate(2)   // fails, but we don't stop
        await yieldUntil { fake.startedCommandIDs == [c0.id, c1.id, c2.id] }
        try! XCTUnwrap(fake.controller(for: c2.id)).terminate(0)
        await yieldUntil { m.chainStates[chain.id] == .failed(atIndex: 1, code: 2) }

        XCTAssertEqual(fake.startedCommandIDs, [c0.id, c1.id, c2.id], "all steps were started")
    }

    func testChainWithDaemonStepAdvances() async {
        let fake = FakeCommandRunner()
        let daemon = cmd("d", daemon: true), c1 = cmd("b")
        let chain = Chain(id: UUID(), name: "seq", commandIDs: [daemon.id, c1.id], stopOnError: true)
        let m = ProcessManager(runner: fake)

        m.run(chain, commands: map([daemon, c1]))
        await yieldUntil { fake.startedCommandIDs == [daemon.id] }
        try! XCTUnwrap(fake.controller(for: daemon.id)).started(pid: 50)   // reaches daemonRunning
        await yieldUntil { fake.startedCommandIDs == [daemon.id, c1.id] }   // chain advanced

        try! XCTUnwrap(fake.controller(for: c1.id)).terminate(0)
        await yieldUntil { m.chainStates[chain.id] == .succeeded }

        XCTAssertEqual(m.states[daemon.id], .daemonRunning, "daemon stays alive after the chain completes")
    }

    func testChainMissingCommandIDFailsAtIndex() async {
        let fake = FakeCommandRunner()
        let c0 = cmd("a")
        let missing = UUID()
        let chain = Chain(id: UUID(), name: "seq", commandIDs: [c0.id, missing], stopOnError: true)
        let m = ProcessManager(runner: fake)

        m.run(chain, commands: map([c0]))   // missing is not in the map
        await yieldUntil { fake.startedCommandIDs == [c0.id] }
        try! XCTUnwrap(fake.controller(for: c0.id)).terminate(0)
        await yieldUntil { if case .failed(atIndex: 1, _) = m.chainStates[chain.id] { return true }; return false }

        XCTAssertEqual(fake.startedCommandIDs, [c0.id], "a missing step does not start")
    }

    func testChainSudoCancelStopsChain() async {
        let fake = FakeCommandRunner()
        let c0 = cmd("a"), sudoStep = cmd("s", sudo: true), c2 = cmd("c")
        // stopOnError=false, but a cancel must still stop the chain.
        let chain = Chain(id: UUID(), name: "seq", commandIDs: [c0.id, sudoStep.id, c2.id], stopOnError: false)
        let m = ProcessManager(runner: fake)

        m.run(chain, commands: map([c0, sudoStep, c2]))
        await yieldUntil { fake.startedCommandIDs == [c0.id] }
        try! XCTUnwrap(fake.controller(for: c0.id)).terminate(0)
        await yieldUntil { fake.startedCommandIDs == [c0.id, sudoStep.id] }
        try! XCTUnwrap(fake.controller(for: sudoStep.id)).cancel()
        await yieldUntil { m.chainStates[chain.id] == .stopped }

        XCTAssertEqual(fake.startedCommandIDs, [c0.id, sudoStep.id], "step 3 does not start after the cancel")
    }

    func testDirectRunOfLiveChainStepDoesNotOrphanChain() async {
        // The command is the live current chain step. A direct ▶ click on it (same id in the
        // "Commands" section) must not hang the chain forever (HIGH-severity review bug).
        let fake = FakeCommandRunner()
        let c0 = cmd("a")
        let chain = Chain(id: UUID(), name: "x", commandIDs: [c0.id], stopOnError: true)
        let m = ProcessManager(runner: fake)

        m.run(chain, commands: map([c0]))
        await yieldUntil { fake.startedCommandIDs == [c0.id] }
        try! XCTUnwrap(fake.controller(for: c0.id)).started()   // step is live, has not terminated

        m.run(c0)   // direct run of the same command — preempts the chain step

        await yieldUntil { m.chainStates[chain.id] == .stopped }
        XCTAssertEqual(m.chainStates[chain.id], .stopped, "chain must be stopped, not left hanging")
    }

    func testStopChainCancelsCurrentLeavesEarlierDaemons() async {
        let fake = FakeCommandRunner()
        let daemon = cmd("d", daemon: true), c1 = cmd("b")
        let chain = Chain(id: UUID(), name: "seq", commandIDs: [daemon.id, c1.id], stopOnError: true)
        let m = ProcessManager(runner: fake)

        m.run(chain, commands: map([daemon, c1]))
        await yieldUntil { fake.startedCommandIDs == [daemon.id] }
        try! XCTUnwrap(fake.controller(for: daemon.id)).started(pid: 50)
        await yieldUntil { fake.startedCommandIDs == [daemon.id, c1.id] }
        try! XCTUnwrap(fake.controller(for: c1.id)).started()
        await yieldUntil { m.states[c1.id] == .running }

        m.stopChain(chain.id)
        await yieldUntil { m.chainStates[chain.id] == .stopped }

        XCTAssertEqual(m.states[daemon.id], .daemonRunning, "previously started daemon remains alive")
        XCTAssertEqual(try! XCTUnwrap(fake.controller(for: c1.id)).stopCount, 1, "current step was stopped")
    }
}
