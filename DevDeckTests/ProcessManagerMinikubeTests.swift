import XCTest
@testable import DevDeck

@MainActor
final class ProcessManagerMinikubeTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    private func sample(anonGiB: UInt64, rustc: Int = 0, rssGiB: UInt64 = 0) -> MinikubeSample {
        MinikubeSample(anonBytes: anonGiB * gib, limitBytes: 4 * gib,
                       rustcCount: rustc, rustcRSSBytes: rssGiB * gib)
    }

    private func cmd() -> Command { Command(id: UUID(), name: "build", command: "just dev-build") }

    func testPeakAccumulatesAndFlushesOnTerminate() async {
        let fake = FakeCommandRunner()
        let probe = FakeMinikubeProbe([
            sample(anonGiB: 2, rustc: 6, rssGiB: 1),
            sample(anonGiB: 3, rustc: 4, rssGiB: 2),   // peak anon, but fewer rustc processes
            sample(anonGiB: 1, rustc: 5, rssGiB: 1),
        ])
        let m = ProcessManager(runner: fake, minikubeProbe: probe,
                               minikubeMonitoringEnabled: { true })
        let c = cmd()
        fake.eagerScripts[c.id] = [.started(pid: 1)]
        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        await yieldUntil { m.states[c.id] == .running }

        m.recordMinikubeSample(for: c.id)   // anon 2, rustc 6
        m.recordMinikubeSample(for: c.id)   // anon 3 (peak)
        m.recordMinikubeSample(for: c.id)   // anon 1
        let stats = try! XCTUnwrap(m.minikubeRunStats(for: c.id))
        XCTAssertEqual(stats.peak.anonBytes, 3 * gib)
        XCTAssertEqual(stats.maxRustcCount, 6)
        XCTAssertEqual(stats.maxRustcRSSBytes, 2 * gib)

        ctrl.terminate(0)
        await yieldUntil { m.states[c.id] == .succeeded }
        XCTAssertNil(m.minikubeRunStats(for: c.id), "stats are cleared on termination")
    }

    func testDisabledFlagSkipsSampling() {
        let m = ProcessManager(runner: FakeCommandRunner(),
                               minikubeProbe: FakeMinikubeProbe([sample(anonGiB: 2)]),
                               minikubeMonitoringEnabled: { false })
        let id = UUID()
        m.recordMinikubeSample(for: id)
        XCTAssertNil(m.minikubeRunStats(for: id))
    }

    func testOOMScanRunsOnFailure() async {
        let fake = FakeCommandRunner()
        let inspector = FakeOOMInspector()
        let m = ProcessManager(runner: fake, oomInspector: inspector,
                               minikubeMonitoringEnabled: { true })
        let c = cmd()
        fake.eagerScripts[c.id] = [.started(pid: 1)]
        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        await yieldUntil { m.states[c.id] == .running }

        ctrl.terminate(101)   // build failure
        await yieldUntil { m.states[c.id] == .failed(code: 101) }
        await sleepUntil({ inspector.calls == 1 }, message: "OOM scan must run after a failure")
    }

    func testOOMScanSkippedOnSuccessUserStopAndDisabledFlag() async {
        // Success → no scan.
        let fake = FakeCommandRunner()
        let inspector = FakeOOMInspector()
        let m = ProcessManager(runner: fake, oomInspector: inspector,
                               minikubeMonitoringEnabled: { true })
        let c = cmd()
        fake.eagerScripts[c.id] = [.started(pid: 1)]
        m.run(c)
        var ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        await yieldUntil { m.states[c.id] == .running }
        ctrl.terminate(0)
        await yieldUntil { m.states[c.id] == .succeeded }

        // User stop (non-zero code on SIGTERM) → no scan.
        fake.eagerScripts[c.id] = [.started(pid: 2)]
        m.run(c)
        ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        await yieldUntil { m.states[c.id] == .running }
        m.stop(c.id)
        ctrl.terminate(143)
        await yieldUntil { m.states[c.id] == .idle }

        try? await Task.sleep(for: .milliseconds(100))   // give the detached task a chance to run
        XCTAssertEqual(inspector.calls, 0, "scan must not run on success or user stop")

        // Flag disabled → no scan even on failure.
        let off = FakeOOMInspector()
        let m2 = ProcessManager(runner: fake, oomInspector: off,
                                minikubeMonitoringEnabled: { false })
        let c2 = cmd()
        fake.eagerScripts[c2.id] = [.started(pid: 3)]
        m2.run(c2)
        let ctrl2 = try! XCTUnwrap(fake.controller(for: c2.id))
        await yieldUntil { m2.states[c2.id] == .running }
        ctrl2.terminate(1)
        await yieldUntil { m2.states[c2.id] == .failed(code: 1) }
        try? await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(off.calls, 0, "disabled flag suppresses the OOM scan")
    }
}
