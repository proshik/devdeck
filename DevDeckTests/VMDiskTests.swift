import XCTest
@testable import DevDeck

final class VMDiskTests: XCTestCase {

    // Real `df -Pk /var/lib/docker` output from the colima VM.
    private let sample = """
    Filesystem     1024-blocks     Used Available Capacity Mounted on
    /dev/vdb1        102087160 41940044  55372340      44% /var/lib/docker
    """

    func testParseDF() throws {
        let info = try XCTUnwrap(parseDF(sample))
        XCTAssertEqual(info.totalBytes, 102_087_160 * 1024)
        XCTAssertEqual(info.usedBytes, 41_940_044 * 1024)
    }

    func testParseDFRejectsGarbage() {
        XCTAssertNil(parseDF(""))
        XCTAssertNil(parseDF("no such file or directory"))
        XCTAssertNil(parseDF("Filesystem 1024-blocks Used\n/dev/vdb1 abc def"))
        // Zero total must not produce a division-by-zero cell.
        XCTAssertNil(parseDF("Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vdb1 0 0 0 0% /x"))
    }

    func testFractionAndFormat() {
        let gib: UInt64 = 1_073_741_824
        let info = VMDiskInfo(usedBytes: 40 * gib, totalBytes: 97 * gib)
        XCTAssertEqual(info.fraction, 40.0 / 97.0, accuracy: 0.001)
        XCTAssertEqual(info.format(), "40 / 97 GB · 41%")
    }
}

@MainActor
final class ProcessManagerDiskTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    func testRefreshVMDiskPopulatesCache() async {
        let probe = FakeVMDiskProbe(VMDiskInfo(usedBytes: 40 * gib, totalBytes: 97 * gib))
        let m = ProcessManager(runner: FakeCommandRunner(), diskProbe: probe)
        await m.refreshVMDisk()
        XCTAssertEqual(m.cachedVMDisk, VMDiskInfo(usedBytes: 40 * gib, totalBytes: 97 * gib))
    }

    func testRefreshVMDiskClearsWhenDisabled() async {
        let probe = FakeVMDiskProbe(VMDiskInfo(usedBytes: 40 * gib, totalBytes: 97 * gib))
        let m = ProcessManager(runner: FakeCommandRunner(),
                               vmMonitoringEnabled: { false }, diskProbe: probe)
        await m.refreshVMDisk()
        XCTAssertNil(m.cachedVMDisk)
        XCTAssertEqual(probe.sampleCount, 0)
    }

    func testDiskThresholdNotifiesOncePerRun() {
        let notifier = FakeNotifier()
        let m = ProcessManager(runner: FakeCommandRunner(), notifier: notifier)

        // 92% (>= 90%) → one warning; repeat must NOT re-notify (debounced per run).
        m.checkDiskThreshold(VMDiskInfo(usedBytes: 92 * gib, totalBytes: 100 * gib))
        m.checkDiskThreshold(VMDiskInfo(usedBytes: 95 * gib, totalBytes: 100 * gib))
        // Below threshold and nil never notify.
        m.checkDiskThreshold(VMDiskInfo(usedBytes: 50 * gib, totalBytes: 100 * gib))
        m.checkDiskThreshold(nil)

        XCTAssertEqual(notifier.posted.count, 1)
        guard case .diskThreshold = notifier.posted.first else {
            return XCTFail("expected diskThreshold, got \(notifier.posted)")
        }
    }
}

@MainActor
final class ProcessManagerHostRefreshTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    private func sample(swapOuts: UInt64) -> HostMetricsSample {
        HostMetricsSample(pressure: .normal, swapInsPages: 0, swapOutsPages: swapOuts,
                          compressorPages: 0, totalBytes: 16 * gib, buildFootprintBytes: 0)
    }

    func testRefreshHostSamplePopulatesCacheAndRate() async throws {
        let probe = FakeHostMetricsProbe([sample(swapOuts: 0), sample(swapOuts: 1000)])
        let m = ProcessManager(runner: FakeCommandRunner(), hostProbe: probe)

        await m.refreshHostSample()
        XCTAssertNotNil(m.cachedHostSample)
        XCTAssertNil(m.cachedSwapOutRatePages)   // first call only records the baseline

        await m.refreshHostSample()
        XCTAssertEqual(m.cachedHostSample?.swapOutsPages, 1000)
        let rate = try XCTUnwrap(m.cachedSwapOutRatePages)
        XCTAssertGreaterThan(rate, 0)            // 1000 pages over a sub-second dt
        XCTAssertNil(probe.lastBuildPID)         // outside a run there is no build PID
    }

    func testRefreshHostSampleNoopWhenDisabled() async {
        let probe = FakeHostMetricsProbe([sample(swapOuts: 0)])
        let m = ProcessManager(runner: FakeCommandRunner(),
                               hostProbe: probe, hostMonitoringEnabled: { false })
        await m.refreshHostSample()
        XCTAssertNil(m.cachedHostSample)
    }
}

final class SwapSeverityTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    func testThresholds() {
        let ram = 64 * gib
        // < 10% of RAM — macOS keeping a couple of GB swapped is healthy.
        XCTAssertEqual(SystemMemory.swapSeverity(swapUsedBytes: 0, totalRAMBytes: ram), .normal)
        XCTAssertEqual(SystemMemory.swapSeverity(swapUsedBytes: 6 * gib, totalRAMBytes: ram), .normal)
        // >= 10% — elevated (exact boundary: 4 of 40 GiB divides evenly, no truncation).
        XCTAssertEqual(SystemMemory.swapSeverity(swapUsedBytes: 7 * gib, totalRAMBytes: ram), .elevated)
        XCTAssertEqual(SystemMemory.swapSeverity(swapUsedBytes: 4 * gib, totalRAMBytes: 40 * gib), .elevated)
        // >= 25% — high (16 of 64 GiB is exactly 0.25).
        XCTAssertEqual(SystemMemory.swapSeverity(swapUsedBytes: 16 * gib, totalRAMBytes: ram), .high)
        // Zero RAM (syscall failure) must not crash → normal.
        XCTAssertEqual(SystemMemory.swapSeverity(swapUsedBytes: gib, totalRAMBytes: 0), .normal)
    }
}
