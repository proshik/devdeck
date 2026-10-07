import AppKit
import SwiftUI

/// AppKit keeps selection, keyboard navigation and accessibility; hover only adds a tint.
final class PanelSegmentedControl: NSSegmentedControl {
    private var hoverArea: NSTrackingArea?
    private var hoverPoint: NSPoint?

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

/// Named native tabs keep every available section visible below the panel header.
struct PanelSectionPicker: NSViewRepresentable {
    @Binding var selection: PanelSection
    var sections: [PanelSectionLayout] = PanelConfiguration.standard.sections

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = PanelSegmentedControl()
        control.controlSize = .regular
        control.segmentStyle = .rounded
        control.selectedSegmentBezelColor = .controlAccentColor
        control.segmentDistribution = .fill
        control.font = .systemFont(ofSize: NSFont.systemFontSize)
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectSection(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        let sections = self.sections
        control.segmentCount = sections.count
        control.setAccessibilityLabel(L10n.deckSection)
        for (index, section) in sections.enumerated() {
            control.setLabel(section.title, forSegment: index)
            control.setToolTip(section.title, forSegment: index)
        }
        control.selectedSegment = sections.firstIndex { $0.id == selection.rawValue } ?? 0
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

/// User-defined tabs can exceed the tray width; every tab remains reachable by scrolling.
struct PanelSectionTabs: View {
    @Binding var selection: PanelSection
    let sections: [PanelSectionLayout]
    @State private var viewportWidth: CGFloat = 0

    private var requiredWidth: CGFloat {
        sections.reduce(0) { width, section in
            width + (section.title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: NSFont.systemFontSize)]).width + 24
        }
    }
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
