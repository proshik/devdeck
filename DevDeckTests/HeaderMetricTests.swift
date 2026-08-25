import XCTest
@testable import DevDeck

final class HeaderMetricTests: XCTestCase {
    func testEveryMetricHasATitleAndADistinctExplanation() {
        var helps: Set<String> = []
        for metric in HeaderMetric.allCases {
            XCTAssertFalse(metric.title.isEmpty, "\(metric) has no title")
            XCTAssertGreaterThan(metric.help.count, 40, "\(metric) explanation is too thin to help")
            XCTAssertTrue(helps.insert(metric.help).inserted, "\(metric) shares its explanation with another metric")
        }
        XCTAssertEqual(HeaderMetric.allCases.count, 9, "one entry per header cell, memory bar included")
    }
}
