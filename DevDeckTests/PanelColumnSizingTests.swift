import XCTest
@testable import DevDeck

final class PanelColumnSizingTests: XCTestCase {
    private typealias Sizing = PanelColumnSizing
    /// The tab row inside the grouped Form at the default window width (macOS 26 caps the form).
    private let formRow: CGFloat = 683
    /// The same row on macOS 15, whose grouped Form is capped at 600 pt.
    private let narrowFormRow: CGFloat = 588

    private func visibleSliver(count: Int, viewport: CGFloat) -> CGFloat {
        let layout = Sizing.layout(count: count, viewportWidth: viewport)
        let full = floor((viewport + layout.spacing) / (layout.width + layout.spacing))
        return viewport - full * (layout.width + layout.spacing)
    }

    func testColumnsThatFitShareTheRowWithoutScrolling() {
        let layout = Sizing.layout(count: 3, viewportWidth: formRow)
        XCTAssertLessThanOrEqual(3 * layout.width + 2 * layout.spacing, formRow + 0.001)
        XCTAssertGreaterThanOrEqual(layout.width, Sizing.fittingMinimum)
        XCTAssertEqual(layout.spacing, Sizing.spacing)
        XCTAssertFalse(layout.isCompact, "the macOS 26 row keeps the regular columns")
        XCTAssertEqual(Sizing.layout(count: 2, viewportWidth: formRow).width, Sizing.maximum,
                       "few columns stop growing at the maximum width")
    }

    func testTheStandardTabsFitTheNarrowFormOfMacOS15() {
        // Regular columns need 3 × 210 + 2 × 12 = 654 pt; the macOS 15 row is about 588 pt and
        // used to overflow, scrolling the third standard tab out of view at any window width.
        for viewport: CGFloat in [540, narrowFormRow, 600, 640] {
            let layout = Sizing.layout(count: 3, viewportWidth: viewport)
            XCTAssertTrue(layout.isCompact, "viewport \(viewport)")
            XCTAssertLessThanOrEqual(3 * layout.width + 2 * layout.spacing, viewport + 0.001, "viewport \(viewport)")
            XCTAssertGreaterThanOrEqual(layout.width, Sizing.compactMinimum, "viewport \(viewport)")
        }
        XCTAssertGreaterThanOrEqual(Sizing.layout(count: 3, viewportWidth: narrowFormRow).width, 188,
                                    "standard tab titles fit whole in the macOS 15 form")
    }

    func testAnOverflowingRowShowsPartOfTheNextColumn() {
        // Four tabs used to fill the form exactly with three columns, hiding the fourth entirely.
        for viewport: CGFloat in [520, narrowFormRow, 643, formRow] {
            let layout = Sizing.layout(count: 4, viewportWidth: viewport)
            XCTAssertFalse(layout.isCompact, "viewport \(viewport): compact columns would be too narrow")
            XCTAssertGreaterThanOrEqual(visibleSliver(count: 4, viewport: viewport), Sizing.peek,
                                        "viewport \(viewport): the next column must peek in")
        }
        for viewport: CGFloat in [520, 643, formRow, 760, 900] {
            let layout = Sizing.layout(count: 6, viewportWidth: viewport)
            XCTAssertGreaterThanOrEqual(layout.width, Sizing.minimum, "viewport \(viewport)")
            XCTAssertLessThanOrEqual(layout.width, Sizing.maximum, "viewport \(viewport)")
            XCTAssertGreaterThanOrEqual(visibleSliver(count: 6, viewport: viewport), Sizing.peek,
                                        "viewport \(viewport): the next column must peek in")
        }
    }

    func testANarrowRowStillShowsOneWholeColumn() {
        XCTAssertEqual(Sizing.layout(count: 4, viewportWidth: 200).width, Sizing.minimum)
        XCTAssertEqual(Sizing.layout(count: 4, viewportWidth: 0).width, Sizing.minimum, "before the first layout pass")
        XCTAssertEqual(Sizing.layout(count: 0, viewportWidth: formRow).width, Sizing.maximum)
    }
}
