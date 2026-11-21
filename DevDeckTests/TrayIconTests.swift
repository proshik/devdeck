import XCTest
@testable import DevDeck

final class TrayIconTests: XCTestCase {
    func testAccessibilityNamesTheEngineAndItsState() {
        XCTAssertEqual(L10n.trayAccessibility(engineName: nil, running: false), "DevDeck")
        XCTAssertTrue(L10n.trayAccessibility(engineName: "colima", running: true).contains("colima"))
        XCTAssertNotEqual(L10n.trayAccessibility(engineName: "colima", running: true),
                          L10n.trayAccessibility(engineName: "colima", running: false))
    }
}