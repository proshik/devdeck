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

    func testAFixedInsetOnTheFirstSegmentIsCompensated() {
        // macOS 15 (CI): equal explicit widths of 59 gave segment areas 62/59/59/59/59/59.
        let areas: [CGFloat] = [62, 59, 59, 59, 59, 59]
        let widths = PanelSegmentedControl.compensatedWidths(equalWidth: 59, areaWidths: areas)
        let resulting = zip(widths, areas).map { width, area in width + (area - 59) }
        for area in resulting { XCTAssertEqual(area, resulting[0], accuracy: 0.001, "segment areas must be equal") }
        XCTAssertEqual(widths.reduce(0, +), 59 * 6, accuracy: 0.001, "the segments must still fill the control")
        XCTAssertLessThan(widths[0], widths[1], "the inset segment gives the inset back")

        let bothEnds = PanelSegmentedControl.compensatedWidths(equalWidth: 59, areaWidths: [62, 59, 59, 59, 59, 62])
        XCTAssertEqual(bothEnds.reduce(0, +), 59 * 6, accuracy: 0.001)
        XCTAssertEqual(bothEnds[0] + 3, bothEnds[1], accuracy: 0.001)
        XCTAssertEqual(bothEnds[5] + 3, bothEnds[4], accuracy: 0.001)
    }

    func testPixelRoundingOfSegmentAreasIsLeftAlone() {
        // macOS 26: equal widths of 57.17 come out as 57 or 57.5 on the half-point grid.
        let width: CGFloat = 343.0 / 6
        let widths = PanelSegmentedControl.compensatedWidths(equalWidth: width,
                                                             areaWidths: [57, 57.5, 57, 57, 57.5, 57])
        XCTAssertEqual(widths, Array(repeating: width, count: 6))
    }

    func testSegmentAreasInAWindowAreEqualAndFillTheControl() throws {
        let window = NSWindow(contentRect: NSRect(x: -3000, y: -3000, width: 400, height: 60),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let control = PanelSegmentedControl(frame: NSRect(x: 10, y: 10, width: 348, height: 24))
        control.segmentStyle = .rounded
        control.segmentDistribution = .fit
        window.contentView?.addSubview(control)
        PanelSectionPicker.configure(control, sections: [
            PanelSectionLayout(id: PanelSection.environment.rawValue),
            PanelSectionLayout(id: PanelSection.monitoring.rawValue),
            PanelSectionLayout(id: PanelSection.displays.rawValue),
            PanelSectionLayout(id: PanelSection.clipboard.rawValue),
            PanelSectionLayout(id: "custom-\(UUID().uuidString)", name: "Star", icon: "star"),
            PanelSectionLayout(id: "custom-\(UUID().uuidString)", name: "Hammer", icon: "hammer"),
        ])
        window.orderFront(nil)
        for width in [348.0, 357.0] {
            control.setFrameSize(NSSize(width: width, height: 24))
            control.layoutSubtreeIfNeeded()
            let areas = control.segmentAreaWidths()
            XCTAssertEqual(areas.count, 6)
            for area in areas { XCTAssertEqual(area, areas[0], accuracy: 1, "segment areas must be equal at \(width)") }
            XCTAssertEqual(control.intrinsicContentSize.width, width, accuracy: 1)
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
