import XCTest
@testable import DevDeck

final class PanelEdgeAutoscrollTests: XCTestCase {
    private typealias Policy = PanelEdgeAutoscroll
    private let viewport: CGFloat = 800
    private let content: CGFloat = 1400

    func testOnlyTheEdgeZonesScrollAndTheirDirectionFollowsTheEdge() {
        XCTAssertEqual(Policy.velocity(cursorX: viewport / 2, viewportWidth: viewport), 0)
        XCTAssertEqual(Policy.velocity(cursorX: Policy.edgeWidth + 1, viewportWidth: viewport), 0)
        XCTAssertEqual(Policy.velocity(cursorX: viewport - Policy.edgeWidth - 1, viewportWidth: viewport), 0)
        XCTAssertLessThan(Policy.velocity(cursorX: 10, viewportWidth: viewport), 0)
        XCTAssertGreaterThan(Policy.velocity(cursorX: viewport - 10, viewportWidth: viewport), 0)
    }

    func testSpeedGrowsTowardTheEdgeAndSaturatesJustBeyondIt() {
        let inner = Policy.velocity(cursorX: viewport - Policy.edgeWidth + 1, viewportWidth: viewport)
        let middle = Policy.velocity(cursorX: viewport - Policy.edgeWidth / 2, viewportWidth: viewport)
        let edge = Policy.velocity(cursorX: viewport, viewportWidth: viewport)
        XCTAssertEqual(inner, Policy.minimumSpeed, accuracy: 30)
        XCTAssertGreaterThan(middle, inner)
        XCTAssertEqual(edge, Policy.maximumSpeed, accuracy: 0.001)
        XCTAssertEqual(Policy.velocity(cursorX: viewport + Policy.edgeWidth / 2, viewportWidth: viewport),
                       Policy.maximumSpeed, accuracy: 0.001, "overshooting the edge keeps full speed")
        XCTAssertEqual(Policy.velocity(cursorX: viewport + Policy.edgeWidth + 1, viewportWidth: viewport), 0,
                       "a cursor far outside the row has left the zone")
        XCTAssertEqual(Policy.velocity(cursorX: -Policy.edgeWidth / 2, viewportWidth: viewport),
                       -Policy.maximumSpeed, accuracy: 0.001)
    }

    func testOffsetStopsAtBothContentEdges() {
        XCTAssertEqual(Policy.clampedOffset(10, by: -50, contentWidth: content, viewportWidth: viewport), 0)
        XCTAssertEqual(Policy.clampedOffset(590, by: 50, contentWidth: content, viewportWidth: viewport), 600)
        XCTAssertEqual(Policy.clampedOffset(100, by: 25, contentWidth: content, viewportWidth: viewport), 125)
        XCTAssertEqual(Policy.clampedOffset(0, by: 50, contentWidth: 500, viewportWidth: viewport), 0,
                       "content narrower than the row never scrolls")
    }

    func testScrollingStartsOnlyAfterTheCursorDwellsInTheZone() throws {
        var policy = Policy()
        let x = viewport - 5
        XCTAssertNil(policy.step(cursorX: x, cursorInRow: true, viewportWidth: viewport, contentWidth: content,
                                 offset: 0, now: 10, elapsed: Policy.interval))
        XCTAssertNil(policy.step(cursorX: x, cursorInRow: true, viewportWidth: viewport, contentWidth: content,
                                 offset: 0, now: 10 + Policy.dwell / 2, elapsed: Policy.interval))
        let next = try XCTUnwrap(policy.step(cursorX: x, cursorInRow: true, viewportWidth: viewport,
                                             contentWidth: content, offset: 0,
                                             now: 10 + Policy.dwell + Policy.interval, elapsed: Policy.interval))
        XCTAssertGreaterThan(next, 0)
        XCTAssertLessThan(next, 20, "one tick moves smoothly, not by a whole column")
    }

    func testLeavingTheZoneOrTheRowResetsTheDwell() {
        var policy = Policy()
        _ = policy.step(cursorX: viewport - 5, cursorInRow: true, viewportWidth: viewport, contentWidth: content,
                        offset: 0, now: 0, elapsed: 0)
        XCTAssertNil(policy.step(cursorX: viewport / 2, cursorInRow: true, viewportWidth: viewport,
                                 contentWidth: content, offset: 0, now: 0.1, elapsed: Policy.interval))
        XCTAssertNil(policy.step(cursorX: viewport - 5, cursorInRow: true, viewportWidth: viewport,
                                 contentWidth: content, offset: 0, now: 0.15, elapsed: Policy.interval),
                     "re-entering restarts the dwell")
        XCTAssertNil(policy.step(cursorX: viewport - 5, cursorInRow: false, viewportWidth: viewport,
                                 contentWidth: content, offset: 0, now: 1, elapsed: Policy.interval),
                     "a cursor above or below the row never scrolls it")
        XCTAssertNil(policy.step(cursorX: viewport - 5, cursorInRow: true, viewportWidth: viewport,
                                 contentWidth: content, offset: 0, now: 1.1, elapsed: Policy.interval))
    }

    func testSwitchingSidesRestartsTheDwell() throws {
        var policy = Policy()
        _ = policy.step(cursorX: viewport - 5, cursorInRow: true, viewportWidth: viewport, contentWidth: content,
                        offset: 300, now: 0, elapsed: 0)
        XCTAssertNotNil(policy.step(cursorX: viewport - 5, cursorInRow: true, viewportWidth: viewport,
                                    contentWidth: content, offset: 300, now: 1, elapsed: Policy.interval))
        XCTAssertNil(policy.step(cursorX: 5, cursorInRow: true, viewportWidth: viewport, contentWidth: content,
                                 offset: 300, now: 1.05, elapsed: Policy.interval))
        let left = try XCTUnwrap(policy.step(cursorX: 5, cursorInRow: true, viewportWidth: viewport,
                                             contentWidth: content, offset: 300,
                                             now: 1.05 + Policy.dwell + Policy.interval, elapsed: Policy.interval))
        XCTAssertLessThan(left, 300)
    }

    func testNothingHappensAtTheContentEdgeInTheZoneDirection() {
        var policy = Policy()
        for now in stride(from: 0.0, through: 1.0, by: Policy.interval) {
            XCTAssertNil(policy.step(cursorX: viewport - 5, cursorInRow: true, viewportWidth: viewport,
                                     contentWidth: content, offset: content - viewport,
                                     now: now, elapsed: Policy.interval))
            XCTAssertNil(policy.step(cursorX: 5, cursorInRow: true, viewportWidth: viewport,
                                     contentWidth: content, offset: 0, now: now + 2, elapsed: Policy.interval))
        }
    }
}
