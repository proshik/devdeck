import XCTest
@testable import DevDeck

@MainActor
final class EnergyModelTests: XCTestCase {
    private var clock = Date(timeIntervalSinceReferenceDate: 1_000_000)
    private var battery: FakeBatteryProbe!
    private var energy: FakeProcessEnergyProbe!
    private var enabled = true
    private var model: EnergyModel!

    override func setUp() async throws {
        battery = FakeBatteryProbe(onAC)
        energy = FakeProcessEnergyProbe([proc(1, 100)])
        enabled = true
        model = EnergyModel(batteryProbe: battery, energyProbe: energy, observer: FakePowerSourceObserver(),
                            now: { [unowned self] in self.clock })
        // Tests drive `refresh` directly instead of `start`, which would spin the minute loop.
        model.isEnabled = { [unowned self] in self.enabled }
    }

    private let onAC = BatteryState(percent: 100, isCharging: false, onBattery: false, minutesRemaining: nil)
    private let onBattery = BatteryState(percent: 80, isCharging: false, onBattery: true, minutesRemaining: 200)

    private func proc(_ pid: Int32, _ joules: Double) -> ProcessEnergy {
        ProcessEnergy(key: ProcessKey(pid: pid, startAbstime: 1), path: "/bin/p\(pid)", energyNJ: UInt64(joules * 1e9))
    }

    private func advance(_ seconds: TimeInterval) { clock = clock.addingTimeInterval(seconds) }

    func testOnACFromTheStartShowsBatteryButNoTally() async {
        await model.refresh(force: true)
        XCTAssertEqual(model.battery, onAC)
        XCTAssertNil(model.tally)
        XCTAssertEqual(energy.snapshotCount, 0, "no process snapshots while on AC")
    }

    func testUnplugTakesBaselineAndLaterSnapshotsCount() async throws {
        await model.refresh(force: true)
        battery.current = onBattery
        await model.refresh(force: true)
        let tally = try XCTUnwrap(model.tally)
        XCTAssertFalse(tally.missedUnplug, "the AC → battery transition was observed")
        XCTAssertTrue(model.isDischarging)
        XCTAssertTrue(model.consumers.isEmpty)

        advance(60)
        energy.processes = [proc(1, 130)]
        await model.refresh(force: true)
        XCTAssertEqual(model.consumers.first?.joules ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(model.consumers.first?.averageWatts ?? 0, 0.5, accuracy: 0.001)
    }

    func testStartingOnBatteryMarksTheUnplugAsMissed() async throws {
        battery.current = onBattery
        await model.refresh(force: true)
        XCTAssertTrue(try XCTUnwrap(model.tally).missedUnplug)
    }

    func testUnforcedRefreshIsThrottled() async {
        battery.current = onBattery
        await model.refresh(force: true)          // baseline
        advance(3)
        await model.refresh()
        XCTAssertEqual(energy.snapshotCount, 1, "3 s after the last snapshot — skipped")
        advance(EnergyModel.popoverSnapshotInterval)
        await model.refresh()
        XCTAssertEqual(energy.snapshotCount, 2)
        XCTAssertEqual(battery.readCount, 3, "the battery itself is re-read on every call")
    }

    func testReplugFreezesAndNextUnplugResets() async throws {
        await model.refresh(force: true)
        battery.current = onBattery
        await model.refresh(force: true)
        advance(100)
        energy.processes = [proc(1, 150)]
        battery.current = onAC
        await model.refresh(force: true)
        XCTAssertFalse(model.isDischarging)
        XCTAssertEqual(model.consumers.first?.joules ?? 0, 50, accuracy: 0.001, "drain up to the replug is kept")

        advance(600)
        energy.processes = [proc(1, 400)]
        await model.refresh(force: true)
        XCTAssertEqual(model.consumers.first?.joules ?? 0, 50, accuracy: 0.001, "frozen while on AC")

        battery.current = onBattery
        await model.refresh(force: true)
        let tally = try XCTUnwrap(model.tally)
        XCTAssertEqual(tally.since, clock, "a new discharge starts at the new unplug")
        XCTAssertFalse(tally.missedUnplug)
        XCTAssertTrue(model.consumers.isEmpty)
    }

    func testDisabledClearsEverything() async {
        battery.current = onBattery
        await model.refresh(force: true)
        enabled = false
        await model.refresh(force: true)
        XCTAssertNil(model.battery)
        XCTAssertNil(model.tally)
        XCTAssertTrue(model.consumers.isEmpty)
        XCTAssertFalse(model.isDischarging)
    }

    func testNoBatteryShowsNothing() async {
        battery.current = nil
        await model.refresh(force: true)
        XCTAssertNil(model.battery)
        XCTAssertNil(model.tally)
        XCTAssertEqual(energy.snapshotCount, 0)
    }
}
