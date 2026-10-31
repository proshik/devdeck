import XCTest
@testable import DevDeck

private final class HeldEnergyProbe: ProcessEnergyProbing, @unchecked Sendable {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var held = false
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func arm() { lock.lock(); held = true; lock.unlock() }
    func snapshot() -> [ProcessEnergy] {
        lock.lock(); let wait = held; held = false; lock.unlock()
        if wait { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
        return [ProcessEnergy(key: .init(pid: 42, startAbstime: 1), path: "/fake", energyNJ: 100)]
    }
}

@MainActor
final class MonitoringEnergyRaceTests: XCTestCase {
    func testCancellingUIRefreshDoesNotEraseBackgroundDischarge() async {
        let entered = expectation(description: "energy UI snapshot held")
        let probe = HeldEnergyProbe(entered)
        let battery = FakeBatteryProbe(BatteryState(percent: 80, isCharging: false, onBattery: true, minutesRemaining: 100))
        let model = EnergyModel(batteryProbe: battery, energyProbe: probe, observer: FakePowerSourceObserver())
        await model.refresh(force: true)
        let baseline = model.tally?.since
        probe.arm()
        let task = Task { await model.refresh(force: true) }
        await fulfillment(of: [entered], timeout: 1)
        task.cancel(); probe.release.signal(); await task.value
        XCTAssertEqual(model.tally?.since, baseline)
        XCTAssertTrue(model.isDischarging)
    }

    func testDisablingDuringEachEnergyAwaitCannotPublishTally() async {
        for phase in 0...2 {
            let entered = expectation(description: "energy snapshot \(phase)")
            let probe = HeldEnergyProbe(entered)
            let battery = FakeBatteryProbe(BatteryState(percent: 80, isCharging: false, onBattery: true, minutesRemaining: 100))
            let model = EnergyModel(batteryProbe: battery, energyProbe: probe, observer: FakePowerSourceObserver())
            var enabled = true
            model.isEnabled = { enabled }
            if phase > 0 { await model.refresh(force: true) }
            if phase == 2 { battery.current = BatteryState(percent: 80, isCharging: false, onBattery: false, minutesRemaining: nil) }
            probe.arm()
            let task = Task { await model.refresh(force: true) }
            await fulfillment(of: [entered], timeout: 1)
            enabled = false
            probe.release.signal()
            await task.value
            XCTAssertNil(model.battery, "phase \(phase)")
            XCTAssertNil(model.tally, "phase \(phase)")
            XCTAssertFalse(model.isDischarging, "phase \(phase)")
        }
    }
}
