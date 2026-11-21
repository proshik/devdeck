import XCTest
@testable import DevDeck

/// Dragging a chain step in the chain editor: where a drop lands and what order it produces.
final class ChainStepReorderTests: XCTestCase {

    private let steps = ["a", "b", "c", "d"]

    func testDropInUpperHalfLandsAboveTheRowAndLowerHalfBelowIt() {
        XCTAssertEqual(ChainStepReorder.gap(overRow: 2, y: 5, rowHeight: 40), 2)
        XCTAssertEqual(ChainStepReorder.gap(overRow: 2, y: 30, rowHeight: 40), 3)
    }

    func testMovingDownPlacesTheStepAfterTheTarget() {
        // Drag "a" onto the lower half of "c".
        let gap = ChainStepReorder.gap(overRow: 2, y: 30, rowHeight: 40)
        XCTAssertEqual(ChainStepReorder.moving(steps, from: 0, toGap: gap), ["b", "c", "a", "d"])
    }

    func testMovingUpPlacesTheStepBeforeTheTarget() {
        // Drag "d" onto the upper half of "b".
        let gap = ChainStepReorder.gap(overRow: 1, y: 5, rowHeight: 40)
        XCTAssertEqual(ChainStepReorder.moving(steps, from: 3, toGap: gap), ["a", "d", "b", "c"])
    }

    func testMovingToTheEndsOfTheList() {
        XCTAssertEqual(ChainStepReorder.moving(steps, from: 1, toGap: 4), ["a", "c", "d", "b"])
        XCTAssertEqual(ChainStepReorder.moving(steps, from: 2, toGap: 0), ["c", "a", "b", "d"])
    }

    func testGapsNextToTheDraggedStepAreNoOpsWithoutALine() {
        XCTAssertNil(ChainStepReorder.effectiveGap(source: 1, gap: 1, count: 4))
        XCTAssertNil(ChainStepReorder.effectiveGap(source: 1, gap: 2, count: 4))
        XCTAssertEqual(ChainStepReorder.moving(steps, from: 1, toGap: 2), steps)
        XCTAssertEqual(ChainStepReorder.effectiveGap(source: 1, gap: 3, count: 4), 3)
    }

    func testOutOfRangeIndicesLeaveTheOrderAlone() {
        // A step removed while its drag was in flight must not crash or reorder anything.
        XCTAssertNil(ChainStepReorder.effectiveGap(source: 4, gap: 0, count: 4))
        XCTAssertNil(ChainStepReorder.effectiveGap(source: 0, gap: 5, count: 4))
        XCTAssertEqual(ChainStepReorder.moving(steps, from: 7, toGap: 0), steps)
    }

    func testTheSameCommandTwiceMovesByPosition() {
        // A chain may run one command twice; steps are addressed by position, not by id.
        XCTAssertEqual(ChainStepReorder.moving(["x", "y", "x"], from: 2, toGap: 0), ["x", "x", "y"])
    }
}
