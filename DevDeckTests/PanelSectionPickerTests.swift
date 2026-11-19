import AppKit
import XCTest
@testable import DevDeck

@MainActor
final class PanelSectionPickerTests: XCTestCase {
    private let sections = [
        PanelSectionLayout(id: PanelSection.environment.rawValue),
        PanelSectionLayout(id: "custom-\(UUID().uuidString)", name: "Focused tools", icon: "star"),
        PanelSectionLayout(id: "custom-\(UUID().uuidString)", name: "Broken icon", icon: "no.such.symbol.devdeck"),
    ]

    func testSegmentsShowOnlyIconsAndKeepTitlesForTooltipAndVoiceOver() throws {
        let control = NSSegmentedControl()
        PanelSectionPicker.configure(control, sections: sections)

        XCTAssertEqual(control.segmentCount, sections.count)
        for (index, section) in sections.enumerated() {
            XCTAssertEqual(control.label(forSegment: index) ?? "", "", "the tray tab must not render its title")
            let image = try XCTUnwrap(control.image(forSegment: index),
                                      "every tab needs a symbol, falling back for an unknown icon name")
            XCTAssertEqual(image.accessibilityDescription, section.title)
            XCTAssertEqual(control.toolTip(forSegment: index), section.title)
        }
    }

    func testReconfiguringFollowsRemovedAndRenamedTabs() throws {
        let control = NSSegmentedControl()
        PanelSectionPicker.configure(control, sections: sections)
        var renamed = sections[1]
        renamed.name = "Renamed tools"
        PanelSectionPicker.configure(control, sections: [renamed])

        XCTAssertEqual(control.segmentCount, 1)
        XCTAssertEqual(control.toolTip(forSegment: 0), "Renamed tools")
        XCTAssertEqual(try XCTUnwrap(control.image(forSegment: 0)).accessibilityDescription, "Renamed tools")
    }
}
