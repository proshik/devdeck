import SwiftUI
import UniformTypeIdentifiers
import CoreTransferable

private struct PanelRowLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 6) {
            configuration.icon.frame(width: 16)
            configuration.title
        }
    }
}

/// Explicit AppKit accessibility and keyboard behavior for the visibility controls.
/// The checkbox carries its own label even though the row already shows the module name.
private struct PanelVisibilityCheckbox: NSViewRepresentable {
    @Binding var isOn: Bool
    let title: String
    let identifier: String
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSButton {
        let control = NSButton(checkboxWithTitle: "", target: context.coordinator,
                               action: #selector(Coordinator.change(_:)))
        control.controlSize = .small
        return control
    }
    func updateNSView(_ control: NSButton, context: Context) {
        context.coordinator.parent = self
        control.state = isOn ? .on : .off
        control.setAccessibilityLabel(title)
        control.setAccessibilityIdentifier(identifier)
        control.toolTip = title
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSButton, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }
    @MainActor final class Coordinator: NSObject {
        var parent: PanelVisibilityCheckbox
        init(_ parent: PanelVisibilityCheckbox) { self.parent = parent }
        @objc func change(_ control: NSButton) { parent.isOn = control.state == .on }
    }
}

extension UTType {
    static let devDeckPanelItem = UTType(exportedAs: "local.devdeck.panel-item")
}

struct PanelDragItem: Codable, Transferable, Sendable {
    enum Kind: String, Codable, Sendable { case module, section }
    let kind: Kind
    let id: String
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .devDeckPanelItem)
    }
}

/// The menu is shared by the tray and configuration. These are layout operations only;
/// explicit function controls remain on the corresponding settings page.
struct PanelModuleMenu: View {
    @Environment(CommandStore.self) private var store
    let module: PanelModuleID

    var body: some View {
        Button(store.config.panel.isShown(module) ? L10n.panelHide : L10n.panelShow) {
            store.updatePanel {
                if $0.isShown(module) { $0.setModuleVisible(module, false) }
                else { $0.revealModule(module) }
            }
        }
        Menu(L10n.panelMoveTo) {
            ForEach(store.config.panel.sections) { layout in
                if let section = PanelSection(rawValue: layout.id) {
                    Button(layout.title) { store.updatePanel { $0.moveModule(module, to: section) } }
                }
            }
        }
        Button(L10n.panelMoveUp) { store.updatePanel { $0.shiftModule(module, by: -1) } }
            .disabled(position == 0)
        Button(L10n.panelMoveDown) { store.updatePanel { $0.shiftModule(module, by: 1) } }
            .disabled(position == nil || position == moduleCount - 1)
        Divider()
        Button(L10n.panelRemoveModule, role: .destructive) { store.updatePanel { $0.removeModule(module) } }
    }

    private var group: PanelSectionLayout? {
        store.config.panel.sections.first { $0.modules.contains { $0.id == module.rawValue } }
    }
    private var position: Int? { group?.modules.firstIndex { $0.id == module.rawValue } }
    private var moduleCount: Int { group?.modules.count ?? 0 }
}

/// Width of a tab column in the row on the "Panel & Modules" page. Columns that fit share the row.
/// When they do not, whole columns widen so that the next one visibly peeks in at the trailing
/// edge: the grouped Form caps its width, and a row ending exactly on a column boundary used to
/// hide the remaining tabs without any hint that the row scrolls.
///
/// The cap differs by system: macOS 26 leaves the row about 684 pt, macOS 15 caps the grouped
/// Form at 600 pt and leaves about 588 pt. There the regular columns do not fit three across, so
/// the columns tighten their spacing and padding before the row resorts to scrolling.
enum PanelColumnSizing {
    struct Layout: Equatable {
        let width: CGFloat
        let spacing: CGFloat
        /// Tighter spacing between and inside columns; used only when it is what lets every
        /// column fit.
        let isCompact: Bool
    }

    static let spacing: CGFloat = 12
    static let compactSpacing: CGFloat = 8
    /// Narrowest column while the row scrolls; titles and the three controls still fit.
    static let minimum: CGFloat = 220
    /// Slightly narrower columns are fine when nothing is hidden and the row does not scroll.
    static let fittingMinimum: CGFloat = 210
    /// Narrowest compact column: the three controls and a short title. Standard titles fit whole
    /// from about 188 pt, the width the three standard tabs get in the macOS 15 form.
    static let compactMinimum: CGFloat = 172
    static let maximum: CGFloat = 260
    /// How much of the next column stays visible when the row overflows.
    static let peek: CGFloat = 40

    static func layout(count: Int, viewportWidth: CGFloat) -> Layout {
        guard count > 0 else { return Layout(width: maximum, spacing: spacing, isCompact: false) }
        guard viewportWidth > 0 else { return Layout(width: minimum, spacing: spacing, isCompact: false) }
        let columns = CGFloat(count)
        let fitting = (viewportWidth - (columns - 1) * spacing) / columns
        if fitting >= fittingMinimum {
            return Layout(width: min(maximum, fitting), spacing: spacing, isCompact: false)
        }
        let compact = (viewportWidth - (columns - 1) * compactSpacing) / columns
        if compact >= compactMinimum {
            return Layout(width: compact, spacing: compactSpacing, isCompact: true)
        }
        let whole = max(1, ((viewportWidth - peek) / (minimum + spacing)).rounded(.down))
        let width = min(maximum, max(minimum, (viewportWidth - peek) / whole - spacing))
        return Layout(width: width, spacing: spacing, isCompact: false)
    }
}

struct PanelSettingsView: View {
    @Environment(CommandStore.self) private var store
    @State private var targetedSection: String?
    @State private var targetedModule: String?
    @State private var cardsViewportWidth: CGFloat = 0
    @State private var tabDraft: PanelTabDraft?
    /// Scrolls the row of tab columns when a drag lingers at its left or right edge.
    @State private var autoscroller = PanelRowAutoscroller()
    /// Preview of a tab heading drag; the configuration changes only when it is dropped.
    @State private var tabReorder: PanelTabReorder?
    @State private var tabDragSession = 0
    private var columns: PanelColumnSizing.Layout {
        PanelColumnSizing.layout(count: store.config.panel.sections.count, viewportWidth: cardsViewportWidth)
    }
    private var cardWidth: CGFloat { columns.width }
    private var cardSpacing: CGFloat { columns.spacing }

    var body: some View {
        // One grouped Form, like every other settings page: the system owns the page margins,
        // section headers and footers, so the custom tab row lines up with the behavior rows.
        Form {
            Section {
                tabRow
                FormActionRow {
                    Button(L10n.panelRestoreLayout) { store.updatePanel { $0.restoreStandardLayout() } }
                    Button(L10n.panelAddTab) { tabDraft = PanelTabDraft() }
                }
            } header: {
                Text(L10n.panelTabsSection)
            } footer: {
                FormFooter(L10n.panelArrangementHelp)
            }
            Section {
                moduleCatalogue
            } header: {
                Text(L10n.panelAvailableModules)
            } footer: {
                FormFooter(L10n.panelVisibilityHelp)
            }
            Section(L10n.panelBehavior) {
                Toggle(L10n.panelRememberLast, isOn: Binding(
                    get: { store.config.panel.rememberLastSection },
                    set: { value in store.updatePanel { $0.rememberLastSection = value } }
                ))
                Picker(L10n.panelInitialSection, selection: Binding(
                    get: { store.config.panel.initialSection },
                    set: { value in store.updatePanel { $0.initialSection = value } }
                )) {
                    if store.config.panel.sections.isEmpty {
                        Text(L10n.panelNewTab).tag(store.config.panel.initialSection)
                    }
                    ForEach(store.config.panel.sections) { Text($0.title).tag($0.id) }
                }.disabled(store.config.panel.rememberLastSection || store.config.panel.sections.isEmpty)
                Toggle(L10n.panelMemoryInEnvironment, isOn: Binding(
                    get: { store.config.panel.showMemoryInEnvironment },
                    set: { value in store.updatePanel { $0.showMemoryInEnvironment = value } }
                ))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.deckPanel)
        .sheet(item: $tabDraft) { draft in
            PanelTabEditor(draft: draft) { name, icon in
                store.updatePanel {
                    if let section = draft.section { $0.renameSection(section, name: name, icon: icon) }
                    else { $0.addSection(name: name, icon: icon) }
                }
            }
        }
    }

    private var tabRow: some View {
        ScrollView(.horizontal) {
            HStack(alignment: .top, spacing: cardSpacing) {
                if store.config.panel.sections.isEmpty {
                    Text(L10n.panelNoTabs).foregroundStyle(.secondary).padding(.vertical, 12)
                }
                ForEach(rowLayouts) { layout in
                    if let section = PanelSection(rawValue: layout.id) {
                        if tabReorder?.dragged == layout.id {
                            tabPlaceholder(layout, section: section)
                        } else {
                            sectionCard(layout, section: section).frame(width: cardWidth)
                        }
                    }
                }
            }.fixedSize(horizontal: false, vertical: true)
                .overlay {
                    if tabReorder != nil {
                        Color.clear.contentShape(Rectangle())
                            .onDrop(of: [.devDeckPanelItem], delegate: PanelTabRowDropDelegate(
                                reorder: $tabReorder, columnWidth: cardWidth, spacing: cardSpacing,
                                onEnter: { autoscroller.beginTracking() },
                                commit: commitTabDrag))
                    }
                }
                .padding(.vertical, 2)
                .background(PanelRowScrollViewLocator(autoscroller: autoscroller))
        }
        .fixedSize(horizontal: false, vertical: true)
        .scrollBounceBehavior(.basedOnSize)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardsViewportWidth = $0 }
    }

    /// Columns in the previewed order while a tab heading is dragged, otherwise as configured.
    private var rowLayouts: [PanelSectionLayout] {
        let sections = store.config.panel.sections
        guard let tabReorder else { return sections }
        let byID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return tabReorder.previewOrder.compactMap { byID[$0] }
    }

    /// The dragged column keeps its size as an empty dashed slot where the tab will land.
    private func tabPlaceholder(_ layout: PanelSectionLayout, section: PanelSection) -> some View {
        sectionCard(layout, section: section).frame(width: cardWidth).hidden()
            .overlay(RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color(nsColor: .separatorColor), style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
            .allowsHitTesting(false)
    }

    private func beginTabDrag(_ section: PanelSection) {
        tabDragSession += 1
        let session = tabDragSession
        tabReorder = PanelTabReorder(order: store.config.panel.sections.map(\.id), dragged: section.rawValue)
        autoscroller.beginTracking {
            // A drop may still be delivered right after the button goes up; only a drag
            // that ended without one (released outside the row, Esc) is cleared here.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if tabDragSession == session { withAnimation { tabReorder = nil } }
            }
        }
    }

    private func commitTabDrag(_ reorder: PanelTabReorder) {
        tabDragSession += 1
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if !reorder.isNoOp { store.updatePanel { reorder.apply(to: &$0) } }
            tabReorder = nil
        }
    }

    private func sectionCard(_ layout: PanelSectionLayout, section: PanelSection) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: columns.isCompact ? 4 : 6) {
                Label(layout.title, systemImage: layout.symbol).fontWeight(.medium).lineLimit(1)
                    .onDrag {
                        beginTabDrag(section)
                        return PanelDragItem(kind: .section, id: section.rawValue).itemProvider()
                    }
                    .help(layout.title + "\n" + L10n.panelDragSection)
                Spacer(minLength: 4)
                Button(L10n.panelRemoveTab, systemImage: "xmark") {
                    store.updatePanel { $0.removeSection(section) }
                }.labelStyle(.iconOnly).buttonStyle(.borderless).controlHoverFeedback()
                    .help(L10n.panelRemoveTabHelp)
                Menu {
                    Button(L10n.panelEditTab) { tabDraft = PanelTabDraft(layout: layout) }
                    Divider()
                    Button(L10n.panelMoveUp) { store.updatePanel { $0.shiftSection(section, by: -1) } }
                        .disabled(store.config.panel.sections.first?.id == section.rawValue)
                    Button(L10n.panelMoveDown) { store.updatePanel { $0.shiftSection(section, by: 1) } }
                        .disabled(store.config.panel.sections.last?.id == section.rawValue)
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .controlHoverFeedback().help(L10n.panelSectionActions)
                PanelVisibilityCheckbox(isOn: Binding(
                    get: { layout.isVisible },
                    set: { value in store.updatePanel { $0.setSectionVisible(section, value) } }
                ), title: L10n.panelShowSection, identifier: "panel-section-\(section.rawValue)")
            }.padding(.horizontal, 6).frame(minHeight: 28)
                .contentShape(Rectangle())
            ForEach(layout.modules) { placement in
                if let module = PanelModuleID(rawValue: placement.id) { moduleRow(placement, module: module, section: section) }
            }
            if layout.modules.isEmpty {
                Text(L10n.panelDropModules).foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 40)
            }
            Menu(L10n.panelAddModule, systemImage: "plus") {
                ForEach(store.config.panel.availableModules) { module in
                    Button(module.title) { store.updatePanel { $0.moveModule(module, to: section) } }
                }
            }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .controlHoverFeedback().frame(minHeight: 24)
                .disabled(store.config.panel.availableModules.isEmpty).help(L10n.panelDropHere)
        }.font(.callout).labelStyle(PanelRowLabelStyle()).padding(columns.isCompact ? 6 : 8)
        .overlay(RoundedRectangle(cornerRadius: 8)
            .stroke(targetedSection == section.rawValue ? Color.accentColor : Color(nsColor: .separatorColor),
                    lineWidth: targetedSection == section.rawValue ? 2 : 1).allowsHitTesting(false))
        .dropDestination(for: PanelDragItem.self) { items, _ in
            guard let item = items.first else { return false }
            switch item.kind {
            case .module:
                guard let module = PanelModuleID(rawValue: item.id) else { return false }
                store.updatePanel { $0.moveModule(module, to: section) }
            case .section:
                return false // tab headings are reordered by the row's own drop delegate
            }
            return true
        } isTargeted: { targeted in
            if targeted { autoscroller.beginTracking(); targetedSection = section.rawValue }
            else if targetedSection == section.rawValue { targetedSection = nil }
        }
    }

    @ViewBuilder private var moduleCatalogue: some View {
        if store.config.panel.availableModules.isEmpty {
            Text(L10n.panelAllModulesAdded).foregroundStyle(.secondary)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190))], alignment: .leading, spacing: 8) {
                ForEach(store.config.panel.availableModules) { module in
                    HStack(spacing: 6) {
                        Label(module.title, systemImage: module.symbol).lineLimit(1).help(module.title)
                        Spacer(minLength: 4)
                        Menu(L10n.panelAddModule, systemImage: "plus") {
                            ForEach(store.config.panel.sections) { layout in
                                if let section = PanelSection(rawValue: layout.id) {
                                    Button(layout.title) { store.updatePanel { $0.moveModule(module, to: section) } }
                                }
                            }
                        }.labelStyle(.iconOnly).menuStyle(.borderlessButton).menuIndicator(.hidden)
                            .fixedSize().controlHoverFeedback().disabled(store.config.panel.sections.isEmpty)
                            .help(L10n.panelAddTo)
                    }.font(.callout).padding(8)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(Rectangle())
                        .draggable(PanelDragItem(kind: .module, id: module.rawValue))
                }
            }
        }
    }

    private func moduleRow(_ placement: PanelModulePlacement, module: PanelModuleID, section: PanelSection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "line.3.horizontal").frame(width: 10).foregroundStyle(.tertiary)
            Text(module.title).lineLimit(1).help(module.title)
            Spacer(minLength: 4)
            Menu { PanelModuleMenu(module: module) } label: { Image(systemName: "ellipsis") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .controlHoverFeedback().help(L10n.panelModuleActions)
            PanelVisibilityCheckbox(isOn: Binding(
                get: { placement.isVisible },
                set: { value in store.updatePanel { $0.setModuleVisible(module, value) } }
            ), title: L10n.panelShowModule(module.title), identifier: "panel-module-\(module.rawValue)")
        }
        .padding(.horizontal, 6).padding(.vertical, 4).frame(minHeight: 30)
        .background(.quaternary.opacity(placement.isVisible && store.config.panel.sections.first(where: { $0.id == section.rawValue })?.isVisible == true ? 0.6 : 0.25), in: RoundedRectangle(cornerRadius: 6))
        .overlay(alignment: .top) {
            if targetedModule == module.rawValue { Rectangle().fill(.tint).frame(height: 2).allowsHitTesting(false) }
        }
        .contentShape(Rectangle())
        .draggable(PanelDragItem(kind: .module, id: module.rawValue))
        .contextMenu { PanelModuleMenu(module: module) }
        .dropDestination(for: PanelDragItem.self) { items, _ in
            guard let item = items.first, item.kind == .module, let source = PanelModuleID(rawValue: item.id) else { return false }
            store.updatePanel { $0.moveModule(source, to: section, before: module) }; return true
        } isTargeted: { targeted in
            if targeted { autoscroller.beginTracking(); targetedModule = module.rawValue }
            else if targetedModule == module.rawValue { targetedModule = nil }
        }
    }
}
