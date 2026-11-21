import XCTest
@testable import DevDeck

final class PanelColumnSizingTests: XCTestCase {
    private typealias Sizing = PanelColumnSizing
    /// The tab row inside the grouped Form at the default window width (macOS 26 caps the form).
    private let formRow: CGFloat = 683

    private func visibleSliver(count: Int, viewport: CGFloat) -> CGFloat {
        let width = Sizing.width(count: count, viewportWidth: viewport)
        let full = floor((viewport + Sizing.spacing) / (width + Sizing.spacing))
        return viewport - full * (width + Sizing.spacing)
    }

    func testColumnsThatFitShareTheRowWithoutScrolling() {
        let width = Sizing.width(count: 3, viewportWidth: formRow)
        XCTAssertLessThanOrEqual(3 * width + 2 * Sizing.spacing, formRow + 0.001)
        XCTAssertGreaterThanOrEqual(width, Sizing.fittingMinimum)
        XCTAssertEqual(Sizing.width(count: 2, viewportWidth: formRow), Sizing.maximum,
                       "few columns stop growing at the maximum width")
    }

    func testAnOverflowingRowShowsPartOfTheNextColumn() {
        // Four tabs used to fill the form exactly with three columns, hiding the fourth entirely.
        for viewport: CGFloat in [520, 643, formRow, 760, 900] {
            let width = Sizing.width(count: 6, viewportWidth: viewport)
            XCTAssertGreaterThanOrEqual(width, Sizing.minimum, "viewport \(viewport)")
            XCTAssertLessThanOrEqual(width, Sizing.maximum, "viewport \(viewport)")
            XCTAssertGreaterThanOrEqual(visibleSliver(count: 6, viewport: viewport), Sizing.peek,
                                        "viewport \(viewport): the next column must peek in")
        }
    }

    func testANarrowRowStillShowsOneWholeColumn() {
        XCTAssertEqual(Sizing.width(count: 4, viewportWidth: 200), Sizing.minimum)
        XCTAssertEqual(Sizing.width(count: 4, viewportWidth: 0), Sizing.minimum, "before the first layout pass")
        XCTAssertEqual(Sizing.width(count: 0, viewportWidth: formRow), Sizing.maximum)
    }
}
