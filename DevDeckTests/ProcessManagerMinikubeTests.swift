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

/// The popover's own 15 s refresh of the minikube line — and the sampler must not stomp on it.
@MainActor
final class ProcessManagerMinikubeRefreshTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824
    private func sample(anonGiB: UInt64) -> MinikubeSample {
        MinikubeSample(anonBytes: anonGiB * gib, limitBytes: 4 * gib, rustcCount: 0, rustcRSSBytes: 0)
    }

    func testRefreshPopulatesCache() async {
        let probe = FakeMinikubeProbe([sample(anonGiB: 2)])
        let m = ProcessManager(runner: FakeCommandRunner(), minikubeProbe: probe,
                               minikubeMonitoringEnabled: { true })
        await m.refreshMinikubeSample()
        XCTAssertEqual(m.minikubeSample(), sample(anonGiB: 2))
    }

    func testRefreshClearsWhenDisabled() async {
        let probe = FakeMinikubeProbe([sample(anonGiB: 2)])
        let m = ProcessManager(runner: FakeCommandRunner(), minikubeProbe: probe,
                               minikubeMonitoringEnabled: { false })
        await m.refreshMinikubeSample()
        XCTAssertNil(m.minikubeSample())
        XCTAssertEqual(probe.calls, 0, "the ssh probe must never run with the toggle off")
    }

    func testRefreshYieldsToTheSamplerDuringABuild() async throws {
        // While a command runs, the 1 s sampler owns the cache — the popover refresh stays out.
        let fake = FakeCommandRunner()
        let probe = FakeMinikubeProbe([sample(anonGiB: 2)])
        let m = ProcessManager(runner: fake, minikubeProbe: probe, minikubeMonitoringEnabled: { true })
        let c = Command(id: UUID(), name: "build", command: "just dev-build")
        fake.eagerScripts[c.id] = [.started(pid: 1)]
        m.run(c)
        await yieldUntil { m.states[c.id] == .running }
        let before = probe.calls
        await m.refreshMinikubeSample()
        XCTAssertEqual(probe.calls, before, "no second writer while the sampler probes the node")
    }

    func testSamplerLeavesTheLineAloneWhileOnlyDaemonsRun() async throws {
        // Regression: a live daemon (port-forward) keeps the sampler loop running; it used to
        // write nil into the cache every tick, so the popover line was empty almost always.
        let fake = FakeCommandRunner()
        let probe = FakeMinikubeProbe([sample(anonGiB: 3)])
        let m = ProcessManager(runner: fake, minikubeProbe: probe,
                               minikubeMonitoringEnabled: { true }, hostMonitoringEnabled: { false })
        let d = Command(id: UUID(), name: "pf", command: "kubectl port-forward", isDaemon: true)
        fake.eagerScripts[d.id] = [.started(pid: 1)]
        m.run(d)
        await yieldUntil { m.states[d.id] == .daemonRunning }

        await m.refreshMinikubeSample()
        XCTAssertEqual(m.minikubeSample(), sample(anonGiB: 3))

        try await Task.sleep(for: .seconds(1.3))   // let the sampler tick at least once more
        XCTAssertEqual(m.minikubeSample(), sample(anonGiB: 3), "the sampler must not clear it")
        XCTAssertEqual(probe.calls, 1, "daemons are never probed — only the popover refresh was")
    }
}
