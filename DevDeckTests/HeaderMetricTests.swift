import XCTest
@testable import DevDeck

final class HeaderMetricTests: XCTestCase {
    func testEveryMetricHasATitleAndADistinctExplanation() {
        var helps: Set<String> = []
        for metric in HeaderMetric.allCases {
            XCTAssertFalse(metric.title(engineName: "colima").isEmpty, "\(metric) has no title")
            XCTAssertGreaterThan(metric.help.count, 40, "\(metric) explanation is too thin to help")
            XCTAssertTrue(helps.insert(metric.help).inserted, "\(metric) shares its explanation with another metric")
        }
        XCTAssertEqual(HeaderMetric.allCases.count, 10, "one entry per header cell, memory bar included")
    }

    func testEveryGridMetricIsEitherPinnedOrHiddenExactlyOnce() {
        let grid = HeaderMetric.pinned + HeaderMetric.hidden
        XCTAssertEqual(grid.count, Set(grid).count, "a metric appears twice")
        XCTAssertEqual(Set(grid), Set(HeaderMetric.allCases).subtracting([.memory]))
        XCTAssertEqual(HeaderMetric.pinned, [.vmEngine, .diskVM, .cpuLoad])
    }

    func testVMTitleCarriesTheEngineName() {
        XCTAssertEqual(HeaderMetric.vmEngine.title(engineName: "colima"), "VM colima")
        XCTAssertEqual(HeaderMetric.vmEngine.title(engineName: "Docker Desktop"), "VM Docker Desktop")
        XCTAssertEqual(HeaderMetric.vmEngine.title(engineName: nil), "VM")
        XCTAssertEqual(HeaderMetric.cpuLoad.title(engineName: "colima"), HeaderMetric.cpuLoad.title(engineName: nil),
                       "only the VM cell depends on the engine")
    }

    func testColimaProbedMetricsAreHiddenForOtherEngines() {
        for metric in [HeaderMetric.vmEngine, .diskVM, .cluster] {
            XCTAssertTrue(metric.isAvailable(engineKind: .colima), "\(metric)")
            XCTAssertFalse(metric.isAvailable(engineKind: .dockerDesktop), "\(metric)")
            XCTAssertFalse(metric.isAvailable(engineKind: nil), "\(metric)")
        }
        for metric in [HeaderMetric.memory, .swap, .vmMinikube, .pressure, .swapRate, .cpuLoad, .battery] {
            XCTAssertTrue(metric.isAvailable(engineKind: .dockerDesktop), "\(metric)")
            XCTAssertTrue(metric.isAvailable(engineKind: nil), "\(metric)")
        }
    }

    private func alarm(cluster: ClusterHealthLevel? = nil, swap: SwapSeverity? = nil,
                       pressure: MemoryPressureLevel? = nil, swapRateActive: Bool = false,
                       battery: BatteryState? = nil) -> HeaderMetric.Alarm {
        HeaderMetric.hiddenAlarm(cluster: cluster, swap: swap, pressure: pressure,
                                 swapRateActive: swapRateActive, battery: battery)
    }

    private func battery(_ percent: Int, onBattery: Bool) -> BatteryState {
        BatteryState(percent: percent, isCharging: false, onBattery: onBattery, minutesRemaining: nil)
    }

    func testHiddenAlarmIsQuietWhenEverythingIsNormalOrMissing() {
        XCTAssertEqual(alarm(), .none)
        XCTAssertEqual(alarm(cluster: .healthy, swap: .normal, pressure: .normal, battery: battery(90, onBattery: true)), .none)
        XCTAssertEqual(alarm(cluster: .unknown), .none, "an unknown cluster is not an alarm")
    }

    func testHiddenAlarmLevels() {
        XCTAssertEqual(alarm(cluster: .degraded), .warning)
        XCTAssertEqual(alarm(cluster: .down), .critical)
        XCTAssertEqual(alarm(swap: .elevated), .warning)
        XCTAssertEqual(alarm(swap: .high), .critical)
        XCTAssertEqual(alarm(pressure: .warning), .warning)
        XCTAssertEqual(alarm(pressure: .critical), .critical)
        XCTAssertEqual(alarm(swapRateActive: true), .warning)
    }

    func testHiddenAlarmTakesTheWorst() {
        XCTAssertEqual(alarm(cluster: .degraded, pressure: .critical, swapRateActive: true), .critical)
    }

    func testLowBatteryAlarmsOnlyOnBattery() {
        XCTAssertEqual(alarm(battery: battery(20, onBattery: true)), .warning)
        XCTAssertEqual(alarm(battery: battery(10, onBattery: true)), .critical)
        XCTAssertEqual(alarm(battery: battery(21, onBattery: true)), .none)
        XCTAssertEqual(alarm(battery: battery(5, onBattery: false)), .none, "charging from 5% is not an alarm")
    }
}
