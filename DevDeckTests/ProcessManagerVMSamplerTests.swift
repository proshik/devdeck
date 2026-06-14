import XCTest
@testable import DevDeck

@MainActor
final class ProcessManagerVMSamplerTests: XCTestCase {
    private func cmd() -> Command { Command(id: UUID(), name: "build", command: "echo") }

    func testPeakAccumulatesAndLogsOnTerminate() async {
        let fake = FakeCommandRunner()
        let gib: UInt64 = 1_073_741_824
        let probe = FakeVMMemoryProbe([
            VMMemoryInfo(usedBytes: 4 * gib, limitBytes: 10 * gib),
            VMMemoryInfo(usedBytes: 7 * gib, limitBytes: 10 * gib),   // peak
            VMMemoryInfo(usedBytes: 5 * gib, limitBytes: 10 * gib),
        ])
        let m = ProcessManager(runner: fake, vmProbe: probe, vmMonitoringEnabled: { true })
        let c = cmd()
        fake.eagerScripts[c.id] = [.started(pid: 1)]
        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        await yieldUntil { m.states[c.id] == .running }

        m.recordVMSample(for: c.id)   // 4
        m.recordVMSample(for: c.id)   // 7 (peak)
        m.recordVMSample(for: c.id)   // 5
        XCTAssertEqual(m.vmPeakBytes(for: c.id), 7 * gib)

        ctrl.terminate(0)
        await yieldUntil { m.states[c.id] == .succeeded }
        XCTAssertNil(m.vmPeakBytes(for: c.id), "peak is cleared on termination")
    }

    func testDisabledFlagSkipsSampling() {
        let m = ProcessManager(runner: FakeCommandRunner(),
                               vmProbe: FakeVMMemoryProbe([VMMemoryInfo(usedBytes: 9, limitBytes: 10)]),
                               vmMonitoringEnabled: { false })
        let id = UUID()
        m.recordVMSample(for: id)
        XCTAssertNil(m.vmPeakBytes(for: id))
    }

    // MARK: Regression test Fix 1: terminal chain is covered by the sampler

    func testTerminalChainPeakAccumulatesAndFlushesOnTerminate() async {
        let fake = FakeCommandRunner()
        let gib: UInt64 = 1_073_741_824
        let probe = FakeVMMemoryProbe([
            VMMemoryInfo(usedBytes: 3 * gib, limitBytes: 10 * gib),
            VMMemoryInfo(usedBytes: 8 * gib, limitBytes: 10 * gib),   // peak
            VMMemoryInfo(usedBytes: 6 * gib, limitBytes: 10 * gib),
        ])
        let m = ProcessManager(runner: fake, vmProbe: probe, vmMonitoringEnabled: { true })

        let c0 = Command(id: UUID(), name: "step1", command: "echo 1")
        let chain = Chain(id: UUID(), name: "build-terminal", commandIDs: [c0.id],
                          stopOnError: true, openInTerminal: true)

        // Terminal chain: the run is keyed by chain.id in active/consumers.
        m.run(chain, commands: [c0.id: c0])

        // Wait for the run to start and chainStates to be set.
        await yieldUntil { m.chainStates[chain.id] != nil }

        // Trigger .started so that startVMSamplerIfNeeded() is called.
        let ctrl = try! XCTUnwrap(fake.controller(for: chain.id),
                                  "Terminal chain controller must be keyed by chain.id")
        ctrl.started(pid: 42)
        await yieldUntil { m.chainStates[chain.id] == .running(currentIndex: 0) }

        // Manually accumulate samples (same as testPeakAccumulatesAndLogsOnTerminate).
        m.recordVMSample(for: chain.id)   // 3 GiB
        m.recordVMSample(for: chain.id)   // 8 GiB → peak
        m.recordVMSample(for: chain.id)   // 6 GiB < peak, does not replace it
        XCTAssertEqual(m.vmPeakBytes(for: chain.id), 8 * gib, "peak must accumulate under chain.id")

        // Finish the run (code 0 → succeeded).
        ctrl.terminate(0)
        await yieldUntil { m.chainStates[chain.id] == .succeeded }

        XCTAssertNil(m.vmPeakBytes(for: chain.id),
                     "flushVMPeak must clear the terminal chain peak on termination")
    }

    func testTerminalChainPeakFlushedOnCancelled() async {
        let fake = FakeCommandRunner()
        let gib: UInt64 = 1_073_741_824
        let probe = FakeVMMemoryProbe([VMMemoryInfo(usedBytes: 5 * gib, limitBytes: 10 * gib)])
        let m = ProcessManager(runner: fake, vmProbe: probe, vmMonitoringEnabled: { true })

        let c0 = Command(id: UUID(), name: "step1", command: "echo 1")
        let chain = Chain(id: UUID(), name: "build-cancel", commandIDs: [c0.id],
                          stopOnError: true, openInTerminal: true)

        m.run(chain, commands: [c0.id: c0])
        await yieldUntil { m.chainStates[chain.id] != nil }

        let ctrl = try! XCTUnwrap(fake.controller(for: chain.id))
        ctrl.started(pid: 43)
        await yieldUntil { m.chainStates[chain.id] == .running(currentIndex: 0) }

        m.recordVMSample(for: chain.id)   // 5 GiB
        XCTAssertEqual(m.vmPeakBytes(for: chain.id), 5 * gib)

        // Cancellation (analogous to sudo-cancel / forced stop without SIGTERM).
        ctrl.cancel()
        await yieldUntil { m.chainStates[chain.id] == .stopped }

        XCTAssertNil(m.vmPeakBytes(for: chain.id),
                     "flushVMPeak must clear the peak when a terminal chain is .cancelled")
    }
}
