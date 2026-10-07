import SwiftUI

struct PanelTabDraft: Identifiable {
    let id = UUID()
    var section: PanelSection?
    var name: String = L10n.panelNewTab
    var icon = "square.grid.2x2"

    init() {}
    init(layout: PanelSectionLayout) {
        section = PanelSection(rawValue: layout.id)
        name = layout.title
        icon = layout.symbol
    }
}

struct PanelTabEditor: View {
    @Environment(\.dismiss) private var dismiss
    private let draft: PanelTabDraft
    private let onSave: (String, String) -> Void
    @State private var name: String
    @State private var icon: String

    init(draft: PanelTabDraft, onSave: @escaping (String, String) -> Void) {
        self.draft = draft
        self.onSave = onSave
        _name = State(initialValue: draft.name)
        _icon = State(initialValue: draft.icon)
    }

    private var icons: [(id: String, title: String)] {
        [("square.grid.2x2", L10n.panelGridIcon), ("terminal", L10n.deckEnvironment),
         ("waveform.path.ecg", L10n.deckMonitoring), ("display", L10n.deckDisplays),
         ("network", L10n.proxy), ("star", L10n.panelFavoriteIcon), ("bolt", L10n.deckEnergy)]
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(draft.section == nil ? L10n.panelAddTab : L10n.panelEditTab).font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    Text(L10n.panelTabName).gridColumnAlignment(.trailing)
                    TextField(L10n.panelTabName, text: $name).labelsHidden()
                        .frame(minWidth: 0, maxWidth: .infinity)
                        .gridCellUnsizedAxes(.horizontal)
                }
                GridRow {
                    Text(L10n.panelTabIcon)
                    Picker(L10n.panelTabIcon, selection: $icon) {
                        ForEach(icons, id: \.id) { choice in
                            Label(choice.title, systemImage: choice.id).tag(choice.id)
                        }
                        if !icons.contains(where: { $0.id == icon }) {
                            Label(L10n.panelTabIcon, systemImage: icon).tag(icon)
                        }
                    }
                    .labelsHidden()
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Spacer()
                Button(L10n.cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(draft.section == nil ? L10n.deckAdd : L10n.save) {
                    onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), icon)
                    dismiss()
                }.keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 440)
    }
}
