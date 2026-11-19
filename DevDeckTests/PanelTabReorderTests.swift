import XCTest
@testable import DevDeck

final class PanelTabReorderTests: XCTestCase {
    private let width: CGFloat = 220
    private let spacing: CGFloat = 12
    private var slot: CGFloat { width + spacing }
    private let order = ["environment", "monitoring", "displays", "clipboard"]

    private func mid(_ index: Int) -> CGFloat { PanelTabReorder.slotMidX(index, columnWidth: width, spacing: spacing) }

    func testInsertionFollowsColumnMiddles() {
        let mids: [CGFloat] = [110, 342, 574]
        XCTAssertEqual(PanelTabReorder.insertionIndex(cursorX: 0, otherMidXs: mids), 0)
        XCTAssertEqual(PanelTabReorder.insertionIndex(cursorX: 109, otherMidXs: mids), 0, "left of a middle: before it")
        XCTAssertEqual(PanelTabReorder.insertionIndex(cursorX: 111, otherMidXs: mids), 1, "right of a middle: after it")
        XCTAssertEqual(PanelTabReorder.insertionIndex(cursorX: 400, otherMidXs: mids), 2)
        XCTAssertEqual(PanelTabReorder.insertionIndex(cursorX: 5000, otherMidXs: mids), 3)
        XCTAssertEqual(mid(0), 110)
        XCTAssertEqual(mid(2), 2 * slot + 110)
    }

    func testStartsAsANoOpPlaceholderAtTheSourcePosition() throws {
        let reorder = try XCTUnwrap(PanelTabReorder(order: order, dragged: "displays"))
        XCTAssertEqual(reorder.insertion, 2)
        XCTAssertEqual(reorder.previewOrder, order)
        XCTAssertTrue(reorder.isNoOp)
        XCTAssertNil(PanelTabReorder(order: order, dragged: "unknown"))
    }

    func testDraggingRightOpensTheGapAfterTheCrossedColumns() throws {
        var reorder = try XCTUnwrap(PanelTabReorder(order: order, dragged: "environment"))
        // The other columns are shown in slots 1...3 while the placeholder holds slot 0.
        XCTAssertEqual(reorder.displayedOtherMidXs(columnWidth: width, spacing: spacing), [mid(1), mid(2), mid(3)])
        XCTAssertFalse(reorder.update(cursorX: mid(1) - 1, columnWidth: width, spacing: spacing),
                       "over the left half of the next column nothing moves")
        XCTAssertTrue(reorder.update(cursorX: mid(1) + 1, columnWidth: width, spacing: spacing))
        XCTAssertEqual(reorder.previewOrder, ["monitoring", "environment", "displays", "clipboard"])
        XCTAssertTrue(reorder.update(cursorX: mid(3) + 1, columnWidth: width, spacing: spacing))
        XCTAssertEqual(reorder.previewOrder, ["monitoring", "displays", "clipboard", "environment"])
        XCTAssertFalse(reorder.isNoOp)
    }

    func testThePreviewIsStableOverThePlaceholderItself() throws {
        var reorder = try XCTUnwrap(PanelTabReorder(order: order, dragged: "environment"))
        _ = reorder.update(cursorX: mid(1) + 1, columnWidth: width, spacing: spacing)
        // The placeholder now occupies slot 1, right under the cursor; moving across it keeps it there.
        for x in stride(from: mid(1) - width / 2 + 1, through: mid(1) + width / 2, by: 20) {
            XCTAssertFalse(reorder.update(cursorX: x, columnWidth: width, spacing: spacing), "x=\(x)")
        }
        XCTAssertTrue(reorder.update(cursorX: mid(0) - 1, columnWidth: width, spacing: spacing))
        XCTAssertTrue(reorder.isNoOp, "back over the first column's left half restores the start")
    }

    func testDropAppliesExactlyThePreviewedOrder() throws {
        var panel = PanelConfiguration.standard
        let ids = panel.sections.map(\.id)
        for dragged in ids {
            for cursor in [-50, mid(0) + 1, mid(1) + 1, mid(2) + 1, mid(3) + 1] {
                var reorder = try XCTUnwrap(PanelTabReorder(order: ids, dragged: dragged))
                _ = reorder.update(cursorX: cursor, columnWidth: width, spacing: spacing)
                var applied = panel
                reorder.apply(to: &applied)
                XCTAssertEqual(applied.sections.map(\.id), reorder.previewOrder, "\(dragged) at \(cursor)")
            }
        }
        panel.lastSection = "monitoring"
        let reorder = try XCTUnwrap(PanelTabReorder(order: ids, dragged: ids[1]))
        var unchanged = panel
        reorder.apply(to: &unchanged)
        XCTAssertEqual(unchanged, panel, "dropping on the source position changes nothing")
    }

    func testLeavingTheRowRevertsAndCancellingLeavesTheConfigurationAlone() throws {
        let panel = PanelConfiguration.standard
        var reorder = try XCTUnwrap(PanelTabReorder(order: panel.sections.map(\.id), dragged: "environment"))
        _ = reorder.update(cursorX: mid(3) + 1, columnWidth: width, spacing: spacing)
        XCTAssertFalse(reorder.isNoOp)
        reorder.revert()
        XCTAssertTrue(reorder.isNoOp)
        var afterRevert = panel
        reorder.apply(to: &afterRevert)
        XCTAssertEqual(afterRevert, panel, "a drop after leaving the row is the original order")
    }
}
