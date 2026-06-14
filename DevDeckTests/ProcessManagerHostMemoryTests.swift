import XCTest
@testable import DevDeck

@MainActor
final class ProcessManagerHostMemoryTests: XCTestCase {
    private func cmd() -> Command { Command(id: UUID(), name: "build", command: "just dev-build") }

    func testHostFootprintPeakAccumulatesAndClearsOnTerminate() async {
        let gib: UInt64 = 1_073_741_824
        let probe = FakeHostMetricsProbe([
            HostMetricsSample(pressure: .normal, swapInsPages: 0, swapOutsPages: 0,
                              compressorPages: 0, totalBytes: 16 * gib, buildFootprintBytes: 3 * gib),
            HostMetricsSample(pressure: .warning, swapInsPages: 0, swapOutsPages: 0,
                              compressorPages: 0, totalBytes: 16 * gib, buildFootprintBytes: 7 * gib),
            HostMetricsSample(pressure: .normal, swapInsPages: 0, swapOutsPages: 0,
                              compressorPages: 0, totalBytes: 16 * gib, buildFootprintBytes: 5 * gib),
        ])
        let fake = FakeCommandRunner()
        let m = ProcessManager(runner: fake, hostProbe: probe, hostMonitoringEnabled: { true })
        let c = cmd()
        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        await yieldUntil { m.states[c.id] == .running }
        // Send .started(pid: 99) manually so we can wait for it to be processed before sampling.
        ctrl.started(pid: 99)
        await yieldUntil { m.buildPID(for: c.id) != nil }

        m.recordHostSample(for: c.id)   // footprint 3 GiB
        m.recordHostSample(for: c.id)   // footprint 7 GiB (peak)
        m.recordHostSample(for: c.id)   // footprint 5 GiB
        XCTAssertEqual(m.hostPeakFootprint(for: c.id), 7 * gib)
        XCTAssertEqual(probe.lastBuildPID, 99, "the captured .started PID is footprinted")

        ctrl.terminate(0)
        await yieldUntil { m.states[c.id] == .succeeded }
        XCTAssertNil(m.hostPeakFootprint(for: c.id), "host peak is cleared on termination")
    }

    func testDisabledFlagSkipsHostSampling() {
        let m = ProcessManager(runner: FakeCommandRunner(),
                               hostProbe: FakeHostMetricsProbe([]), hostMonitoringEnabled: { false })
        let id = UUID()
        m.recordHostSample(for: id)
        XCTAssertNil(m.hostPeakFootprint(for: id))
    }

    func testTerminateWritesHostSummaryToLog() async throws {
        let gib: UInt64 = 1_073_741_824
        let probe = FakeHostMetricsProbe([
            HostMetricsSample(pressure: .warning, swapInsPages: 0, swapOutsPages: 0,
                              compressorPages: 0, totalBytes: 16 * gib, buildFootprintBytes: 6 * gib),
        ])
        let fake = FakeCommandRunner()
        let m = ProcessManager(runner: fake, hostProbe: probe, hostMonitoringEnabled: { true })
        let c = Command(id: UUID(), name: "heavy-build", command: "just dev-build")
        fake.eagerScripts[c.id] = [.started(pid: 7)]
        m.run(c)
        let ctrl = try XCTUnwrap(fake.controller(for: c.id))
        await yieldUntil { m.buildPID(for: c.id) != nil }
        m.recordHostSample(for: c.id)

        let before = (try? String(contentsOf: DiagnosticLog.shared.fileURL, encoding: .utf8)) ?? ""
        ctrl.terminate(0)
        await yieldUntil { m.states[c.id] == .succeeded }
        let after = try String(contentsOf: DiagnosticLog.shared.fileURL, encoding: .utf8)
        let added = String(after.dropFirst(before.count))
        XCTAssertTrue(added.contains("Host peak for \u{201c}heavy-build\u{201d}"), added)
        XCTAssertTrue(added.contains("6.0 GB"), "build footprint peak in the summary: \(added)")
    }
}
