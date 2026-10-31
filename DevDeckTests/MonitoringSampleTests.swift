import XCTest
@testable import DevDeck

final class MonitoringSampleTests: XCTestCase {
    func testCPUBusyUsesCounterDeltasAndNeverInventsZeroForMissingIntervals() {
        var delta = CPUBusyDelta()
        XCTAssertNil(delta.consume(.init(user: 10, system: 10, idle: 80, nice: 0)))
        XCTAssertEqual(delta.consume(.init(user: 30, system: 20, idle: 150, nice: 0)), 30)
        XCTAssertNil(delta.consume(.init(user: 30, system: 20, idle: 150, nice: 0)), "unchanged counters are not 0% busy")
        XCTAssertNil(delta.consume(.init(user: 1, system: 1, idle: 1, nice: 0)), "reset cannot become a spike")
        XCTAssertEqual(delta.consume(.init(user: 1, system: 1, idle: 101, nice: 0)), 0, "a measured idle interval really is zero")
        XCTAssertNil(delta.consume(nil))
        XCTAssertNil(delta.consume(.init(user: 100, system: 100, idle: 100, nice: 0)), "missing read breaks the baseline")
        delta.reset()
        XCTAssertNil(delta.consume(.init(user: 200, system: 200, idle: 100, nice: 0)), "resume must start a new interval")
    }

    func testPowerDetailsDoNotInventHealthWattsOrAnInternalBattery() {
        let absent = PowerDetails.decode(nil)
        XCTAssertFalse(absent.hasBattery)
        XCTAssertNil(absent.cycles)
        XCTAssertNil(absent.batteryWatts)
        let present = PowerDetails.decode(["CycleCount": 96, "Voltage": 12000, "InstantAmperage": -1000,
                                          "AdapterDetails": ["Watts": 65], "BatteryHealth": "Good"])
        XCTAssertEqual(present.batteryWatts, -12)
        XCTAssertEqual(present.adapterWatts, 65)
        XCTAssertEqual(present.cycles, 96)
        XCTAssertEqual(present.health, "Good")
        let incomplete = PowerDetails.decode(["Voltage": 12000, "DesignCapacity": 6000])
        XCTAssertTrue(incomplete.hasBattery)
        XCTAssertNil(incomplete.batteryWatts)
        XCTAssertNil(incomplete.health)
    }
}
