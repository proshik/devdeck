import XCTest
@testable import DevDeck

/// The restore flag is a behaviour setting like the monitoring ones: it lives in config.json,
/// decodes with a default, and survives a round trip.
final class ClaudeTabsSettingsTests: XCTestCase {

    func testDefaultsToOffWhenKeyMissing() throws {
        let json = Data(#"{"commands":[]}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertFalse(config.settings.claudeTabsRestore)
    }

    func testRoundTrips() throws {
        var config = Config()
        config.settings.claudeTabsRestore = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertTrue(decoded.settings.claudeTabsRestore)
    }

    func testCaptureIntervalDefaultsTo15WhenKeyMissing() throws {
        let json = Data(#"{"commands":[]}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertEqual(config.settings.claudeTabsCaptureSeconds, 15)
    }

    func testCaptureIntervalRoundTrips() throws {
        var config = Config()
        config.settings.claudeTabsCaptureSeconds = 45
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertEqual(decoded.settings.claudeTabsCaptureSeconds, 45)
    }
}
