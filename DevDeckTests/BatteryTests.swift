import XCTest
@testable import DevDeck

/// Expectations are built from the L10n catalog rather than literals: switching the language here
/// would write the test host's (= the real app's) UserDefaults.
final class BatteryTests: XCTestCase {
    func testFormatOnBatteryWithEstimate() {
        let state = BatteryState(percent: 64, isCharging: false, onBattery: true, minutesRemaining: 130)
        XCTAssertEqual(state.format(), "64% · " + L10n.batteryTimeLeft(hours: 2, minutes: 10))
    }

    func testTimeLeftOmitsZeroHours() {
        XCTAssertEqual(L10n.batteryTimeLeft(hours: 0, minutes: 42), t("42 min", "42 мин"))
        XCTAssertEqual(L10n.batteryTimeLeft(hours: 2, minutes: 10), t("2 h 10 min", "2 ч 10 мин"))
    }

    func testFormatOnBatteryWhileEstimating() {
        let state = BatteryState(percent: 64, isCharging: false, onBattery: true, minutesRemaining: nil)
        XCTAssertEqual(state.format(), "64%")
    }

    func testFormatOnAC() {
        XCTAssertEqual(BatteryState(percent: 87, isCharging: true, onBattery: false, minutesRemaining: nil).format(),
                       "87% · " + L10n.batteryCharging)
        XCTAssertEqual(BatteryState(percent: 100, isCharging: false, onBattery: false, minutesRemaining: 50).format(),
                       "100% · " + L10n.batteryOnAC, "an estimate is ignored on AC")
    }
}
