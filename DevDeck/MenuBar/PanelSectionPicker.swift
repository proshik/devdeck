import AppKit
import SwiftUI

/// AppKit keeps selection, keyboard navigation and accessibility; hover only adds a tint.
///
/// Segments get explicit widths so that the actual segment areas are equal and fill the
/// control on every supported macOS. `.fillEqually` alone is not honored everywhere (on 15
/// the segments kept their content widths), and on 15 AppKit also adds a fixed end inset
/// to the first segment's area, so equal explicit widths still left it 3 pt wider. The
/// control therefore measures the real segment areas once per size and compensates.
final class PanelSegmentedControl: NSSegmentedControl {
    private var hoverArea: NSTrackingArea?
    private var hoverPoint: NSPoint?
    /// Width the bezel and separators add on top of the segment widths, per segment count.
    private var chromeWidth: (count: Int, width: CGFloat)?
    /// Size whose widths were already compensated against the measured segment areas.
    private var calibrated: (count: Int, width: CGFloat)?

    override var segmentCount: Int {
        didSet { equalizeSegmentWidths() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        equalizeSegmentWidths()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        equalizeSegmentWidths()
    }

    override func layout() {
        super.layout()
        equalizeSegmentWidths()
    }

    /// Gives every segment an explicit width so that their areas are equal and fill `bounds`.
    func equalizeSegmentWidths() {
        let count = segmentCount
        guard count > 0, bounds.width > 0 else { return }
        if calibrated?.count == count, calibrated?.width == bounds.width { return }
        if chromeWidth?.count != count {
            // Measure the fixed overhead once: intrinsic width minus known segment widths.
            let probe: CGFloat = 40
            for index in 0..<count { setWidth(probe, forSegment: index) }
            chromeWidth = (count, max(intrinsicContentSize.width - probe * CGFloat(count), 0))
        }
        let width = max((bounds.width - (chromeWidth?.width ?? 0)) / CGFloat(count), 1)
        for index in 0..<count { setWidth(width, forSegment: index) }
        // The real segment areas (the same ones AppKit hit-tests and highlights) are only
        // known in a window; without one, keep the equal widths and calibrate later.
        let areas = segmentAreaWidths()
        guard window != nil, areas.count == count else { return }
        let compensated = Self.compensatedWidths(equalWidth: width, areaWidths: areas)
        for index in 0..<count where compensated[index] != width {
            setWidth(compensated[index], forSegment: index)
        }
        calibrated = (count, bounds.width)
    }

    /// Widths of the segment areas as AppKit lays them out, from their accessibility frames.
    func segmentAreaWidths() -> [CGFloat] {
        guard let cell = cell as? NSSegmentedCell else { return [] }
        return (cell.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
            .map { $0.accessibilityFrame().width }
    }

    /// Explicit widths that make every segment area equal while keeping their total.
    /// `areaWidths` were measured with every segment set to `equalWidth`; whole-point
    /// differences are fixed insets AppKit adds to a segment (sub-point ones are pixel
    /// rounding and are left alone).
    static func compensatedWidths(equalWidth: CGFloat, areaWidths: [CGFloat]) -> [CGFloat] {
        let insets = areaWidths.map { ($0 - equalWidth).rounded() }
        guard let first = insets.first, insets.contains(where: { $0 != first }) else {
            return Array(repeating: equalWidth, count: areaWidths.count)
        }
        let target = equalWidth + insets.reduce(0, +) / CGFloat(insets.count)
        return insets.map { max(target - $0, 1) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero,
                                 options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways, .inVisibleRect],
                                 owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        updateHover(with: event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        updateHover(with: event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        hoverPoint = nil
        needsDisplay = true
    }

    private func updateHover(with event: NSEvent) {
        hoverPoint = convert(event.locationInWindow, from: nil)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard isEnabled, let hoverPoint, let window,
              let cell = cell as? NSSegmentedCell else { return }
        // Native segments have unequal widths. Their public accessibility frames reflect
        // the actual AppKit hit areas, including localization, resizing and separators.
        let segments = (cell.accessibilityChildren() ?? []).compactMap { $0 as? any NSAccessibilityProtocol }
        for (index, segment) in segments.enumerated() where index < segmentCount {
            let rect = convert(window.convertFromScreen(segment.accessibilityFrame()), from: nil).intersection(bounds)
            guard rect.contains(hoverPoint), index != selectedSegment, isEnabled(forSegment: index) else { continue }
            NSColor.labelColor.withAlphaComponent(0.10).setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1), xRadius: 5, yRadius: 5).fill()
            break
        }
    }
}

/// Icon-only native tabs keep every available section visible below the panel header.
/// The section title stays reachable as the tooltip and as the VoiceOver label.
struct PanelSectionPicker: NSViewRepresentable {
    @Binding var selection: PanelSection
    var sections: [PanelSectionLayout] = PanelConfiguration.standard.sections

    /// Narrowest equal segment that still shows its symbol with a comfortable hit area.
    static let minimumSegmentWidth: CGFloat = 32
    private static let fallbackSymbol = "square.grid.2x2"
    private static let symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .regular)

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = PanelSegmentedControl()
        control.controlSize = .regular
        control.segmentStyle = .rounded
        control.selectedSegmentBezelColor = .controlAccentColor
        // Explicit widths from PanelSegmentedControl decide the layout on every macOS.
        control.segmentDistribution = .fit
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectSection(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        Self.configure(control, sections: sections)
        control.selectedSegment = sections.firstIndex { $0.id == selection.rawValue } ?? 0
    }

    /// One segment per section: its symbol only, the title as tooltip and accessibility label.
    static func configure(_ control: NSSegmentedControl, sections: [PanelSectionLayout]) {
        control.segmentCount = sections.count
        control.setAccessibilityLabel(L10n.deckSection)
        for (index, section) in sections.enumerated() {
            let image = NSImage(systemSymbolName: section.symbol, accessibilityDescription: section.title)
                ?? NSImage(systemSymbolName: fallbackSymbol, accessibilityDescription: section.title)
            control.setImage(image?.withSymbolConfiguration(symbolConfiguration) ?? image, forSegment: index)
            control.setImageScaling(.scaleProportionallyDown, forSegment: index)
            control.setLabel("", forSegment: index)
            control.setToolTip(section.title, forSegment: index)
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 24)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: PanelSectionPicker
        init(_ parent: PanelSectionPicker) { self.parent = parent }
        @objc func selectSection(_ sender: NSSegmentedControl) {
            guard parent.sections.indices.contains(sender.selectedSegment),
                  let section = PanelSection(rawValue: parent.sections[sender.selectedSegment].id) else { return }
            parent.selection = section
        }
    }
}

/// Equal icon segments share the tray width. Only an unusually long list of tabs, whose
/// segments would fall below the minimum width, scrolls horizontally to stay reachable.
struct PanelSectionTabs: View {
    @Binding var selection: PanelSection
    let sections: [PanelSectionLayout]
    @State private var viewportWidth: CGFloat = 0

    private var requiredWidth: CGFloat { CGFloat(sections.count) * PanelSectionPicker.minimumSegmentWidth }
    var body: some View {
        ScrollView(.horizontal) {
            PanelSectionPicker(selection: $selection, sections: sections)
                .frame(width: max(viewportWidth, requiredWidth), height: 24)
        }
        .frame(height: 24)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { viewportWidth = $0 }
    }
}
