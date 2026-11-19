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

    func testSegmentsGetExplicitEqualWidthsThatFillTheControl() {
        // Symbols of different widths: equal segments must come from the control itself,
        // not from whatever a given macOS does with `.fillEqually`.
        let mixed = [
            PanelSectionLayout(id: PanelSection.environment.rawValue),
            PanelSectionLayout(id: PanelSection.monitoring.rawValue),
            PanelSectionLayout(id: PanelSection.displays.rawValue),
            PanelSectionLayout(id: PanelSection.clipboard.rawValue),
            PanelSectionLayout(id: "custom-\(UUID().uuidString)", name: "Star", icon: "star"),
            PanelSectionLayout(id: "custom-\(UUID().uuidString)", name: "Hammer", icon: "hammer"),
        ]
        let control = PanelSegmentedControl(frame: NSRect(x: 0, y: 0, width: 348, height: 24))
        PanelSectionPicker.configure(control, sections: mixed)
        for width in [348.0, 300.0, 200.0] {
            control.setFrameSize(NSSize(width: width, height: 24))
            let widths = (0..<control.segmentCount).map { control.width(forSegment: $0) }
            XCTAssertEqual(widths.count, mixed.count)
            for segment in widths {
                XCTAssertGreaterThan(segment, 0, "every segment needs an explicit width")
                XCTAssertEqual(segment, widths[0], accuracy: 0.01, "segments must be equal at \(width)")
            }
            XCTAssertEqual(control.intrinsicContentSize.width, width, accuracy: 1,
                           "the equal segments must fill the control at \(width)")
        }
        PanelSectionPicker.configure(control, sections: Array(mixed.prefix(3)))
        let three = (0..<control.segmentCount).map { control.width(forSegment: $0) }
        XCTAssertEqual(three.count, 3)
        XCTAssertEqual(control.intrinsicContentSize.width, 200, accuracy: 1, "a new tab count re-divides the width")
        for segment in three { XCTAssertEqual(segment, three[0], accuracy: 0.01) }
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
