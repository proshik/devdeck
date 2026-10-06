import AppKit
import SwiftUI

/// Named native tabs keep every available section visible below the panel header.
struct PanelSectionPicker: NSViewRepresentable {
    @Binding var selection: PanelSection

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
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
        let sections = PanelSection.allCases
        control.segmentCount = sections.count
        control.setAccessibilityLabel(L10n.deckSection)
        for (index, section) in sections.enumerated() {
            control.setLabel(section.title, forSegment: index)
            control.setToolTip(section.title, forSegment: index)
        }
        control.selectedSegment = sections.firstIndex(of: selection) ?? 0
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: 24)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: PanelSectionPicker
        init(_ parent: PanelSectionPicker) { self.parent = parent }
        @objc func selectSection(_ sender: NSSegmentedControl) {
            guard PanelSection.allCases.indices.contains(sender.selectedSegment) else { return }
            parent.selection = PanelSection.allCases[sender.selectedSegment]
        }
    }
}
