import XCTest
@testable import DevDeck

final class EnergyTallyTests: XCTestCase {
    private let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private let vmPath = "/System/Library/Frameworks/Virtualization.framework/Versions/A/XPCServices/com.apple.Virtualization.VirtualMachine.xpc/Contents/MacOS/com.apple.Virtualization.VirtualMachine"

    private func proc(_ pid: Int32, _ path: String, _ joules: Double, start: UInt64 = 1) -> ProcessEnergy {
        ProcessEnergy(key: ProcessKey(pid: pid, startAbstime: start), path: path, energyNJ: UInt64(joules * 1e9))
    }

    func testCountsOnlyEnergyUsedAfterTheBaseline() {
        var tally = EnergyTally(baseline: [proc(1, "/bin/a", 100)], at: t0, missedUnplug: false)
        tally.update([proc(1, "/bin/a", 160)], at: t0.addingTimeInterval(60))
        let top = tally.top(5)
        XCTAssertEqual(top.count, 1)
        XCTAssertEqual(top[0].name, "a")
        XCTAssertEqual(top[0].joules, 60, accuracy: 0.001)
        XCTAssertEqual(top[0].averageWatts, 1, accuracy: 0.001)
        XCTAssertEqual(top[0].share, 1, accuracy: 0.001)
    }

    func testProcessStartedAfterTheBaselineCountsFromZero() {
        var tally = EnergyTally(baseline: [], at: t0, missedUnplug: false)
        tally.update([proc(7, "/bin/new", 30)], at: t0.addingTimeInterval(10))
        XCTAssertEqual(tally.top(5).first?.joules ?? 0, 30, accuracy: 0.001)
    }

    func testExitedProcessKeepsItsLastSeenEnergy() {
        var tally = EnergyTally(baseline: [], at: t0, missedUnplug: false)
        tally.update([proc(7, "/bin/build", 50), proc(8, "/bin/other", 10)], at: t0.addingTimeInterval(60))
        tally.update([proc(8, "/bin/other", 20)], at: t0.addingTimeInterval(120))   // build exited
        let top = tally.top(5)
        XCTAssertEqual(top.map(\.name), ["build", "other"])
        XCTAssertEqual(top[0].joules, 50, accuracy: 0.001)
    }

    func testReusedPIDDoesNotInheritTheOldBaseline() {
        // pid 5 had 1000 J at the unplug; a new process later gets pid 5 and uses 3 J.
        var tally = EnergyTally(baseline: [proc(5, "/bin/old", 1000, start: 1)], at: t0, missedUnplug: false)
        tally.update([proc(5, "/bin/new", 3, start: 2)], at: t0.addingTimeInterval(30))
        XCTAssertEqual(tally.top(5).first?.joules ?? 0, 3, accuracy: 0.001)
    }

    func testGroupsHelpersByAppAndSortsByEnergy() {
        var tally = EnergyTally(baseline: [], at: t0, missedUnplug: false)
        tally.update([
            proc(1, "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome", 10),
            proc(2, "/Applications/Google Chrome.app/Contents/Frameworks/X.framework/Helpers/Google Chrome Helper (Renderer).app/Contents/MacOS/Google Chrome Helper (Renderer)", 25),
            proc(3, vmPath, 30),
            proc(4, "/bin/tiny", 1),
        ], at: t0.addingTimeInterval(100))
        let top = tally.top(2)
        XCTAssertEqual(top.map(\.name), ["Google Chrome", "VM"])
        XCTAssertEqual(top[0].joules, 35, accuracy: 0.001)
        XCTAssertEqual(top[0].share, 35.0 / 66.0, accuracy: 0.001)
    }

    func testNoConsumptionMeansNoRows() {
        var tally = EnergyTally(baseline: [proc(1, "/bin/a", 5)], at: t0, missedUnplug: false)
        tally.update([proc(1, "/bin/a", 5)], at: t0.addingTimeInterval(60))
        XCTAssertTrue(tally.top(5).isEmpty)
    }

    /// A real read (no process launched): the kernel must hand back at least this test process.
    func testLiveProbeSeesThisProcess() {
        let own = LiveProcessEnergyProbe().snapshot().filter { $0.key.pid == getpid() }
        XCTAssertEqual(own.count, 1)
        XCTAssertFalse(own.first?.path.isEmpty ?? true)
        XCTAssertGreaterThan(own.first?.key.startAbstime ?? 0, 0)
    }

    func testDisplayNames() {
        XCTAssertEqual(EnergyTally.displayName(path: vmPath), "VM")
        XCTAssertEqual(EnergyTally.displayName(path: "/Users/me/.local/share/claude/versions/2.1.273"), "Claude Code")
        XCTAssertEqual(EnergyTally.displayName(path: "/Applications/super.engineering.app/Contents/MacOS/superconductor"),
                       "super.engineering")
        XCTAssertEqual(EnergyTally.displayName(path: "/opt/homebrew/bin/limactl"), "limactl")
        XCTAssertEqual(EnergyTally.displayName(path: "rustc"), "rustc")
    }
}
