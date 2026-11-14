import XCTest
@testable import DevDeck

final class MonitoringSettingsTests: XCTestCase {
    func testOldAndPartialConfigsKeepDefaultsAndBoundTheEffectiveInterval() throws {
        let old = try JSONDecoder().decode(Config.self, from: Data("{}".utf8))
        XCTAssertEqual(old.settings.monitoring, MonitoringSettings())
        let partial = try JSONDecoder().decode(MonitoringSettings.self, from: Data(#"{"intervalSeconds":0}"#.utf8))
        XCTAssertTrue(partial.enabled)
        XCTAssertTrue(partial.historyEnabled)
        XCTAssertEqual(partial.interval, 1)
        XCTAssertEqual(MonitoringSettings(intervalSeconds: Int.max).interval, 60)
    }

    func testNetworkOptionsRoundTripAndDefaultIndependently() throws {
        let defaults = try JSONDecoder().decode(MonitoringSettings.self, from: Data("{}".utf8))
        XCTAssertTrue(defaults.networkEnabled); XCTAssertNil(defaults.networkInterface)
        let input = Data(#"{"networkEnabled":false,"networkInterface":"en7","enabled":true}"#.utf8)
        let settings = try JSONDecoder().decode(MonitoringSettings.self, from: input)
        XCTAssertFalse(settings.networkEnabled); XCTAssertTrue(settings.enabled)
        XCTAssertEqual(settings.networkInterface, "en7")
        XCTAssertEqual(try JSONDecoder().decode(MonitoringSettings.self, from: JSONEncoder().encode(settings)), settings)
    }

    func testMonitoringOptionsSurviveConfigRoundTripIndependentlyOfHostToggle() throws {
        let input = Data(#"{"settings":{"hostMemoryMonitoring":false,"monitoring":{"enabled":false,"intervalSeconds":5,"historyEnabled":false}}}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: input)
        let data = try JSONEncoder().encode(config)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let settings = try XCTUnwrap(json["settings"] as? [String: Any])
        let monitoring = try XCTUnwrap(settings["monitoring"] as? [String: Any])
        XCTAssertEqual(monitoring["enabled"] as? Bool, false)
        XCTAssertEqual(monitoring["intervalSeconds"] as? Int, 5)
        XCTAssertEqual(monitoring["historyEnabled"] as? Bool, false)
        XCTAssertEqual(settings["hostMemoryMonitoring"] as? Bool, false)
    }
}
