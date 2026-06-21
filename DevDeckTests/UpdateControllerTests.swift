import XCTest
@testable import DevDeck

final class UpdateControllerTests: XCTestCase {
    func testAppcastSummaryCountsNewerBuilds() {
        let s = appcastSummary(installedBuild: 100, items: [
            (build: 100, display: "0.3.0"),
            (build: 101, display: "0.3.1"),
            (build: 102, display: "0.4.0"),
        ])
        XCTAssertEqual(s.behind, 2, "two builds are newer than 100")
        XCTAssertEqual(s.latest, "0.4.0", "newest display version")
    }

    func testAppcastSummaryUpToDate() {
        let s = appcastSummary(installedBuild: 102, items: [
            (build: 100, display: "0.3.0"),
            (build: 102, display: "0.4.0"),
        ])
        XCTAssertEqual(s.behind, 0)
        XCTAssertNil(s.latest)
    }

    func testAppcastSummaryEmpty() {
        let s = appcastSummary(installedBuild: 50, items: [])
        XCTAssertEqual(s.behind, 0)
        XCTAssertNil(s.latest)
    }
}
