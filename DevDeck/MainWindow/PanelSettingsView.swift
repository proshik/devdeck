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

struct PanelSettingsView: View {
    @Environment(CommandStore.self) private var store
    @State private var targetedSection: String?
    @State private var targetedModule: String?
    @State private var cardsViewportWidth: CGFloat = 0
    @State private var tabDraft: PanelTabDraft?

    private var cardWidth: CGFloat {
        let count = max(store.config.panel.sections.count, 1)
        let fittingWidth = (cardsViewportWidth - CGFloat(count - 1) * 12) / CGFloat(count)
        return min(260, max(220, fittingWidth))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(L10n.panelArrangementHelp).font(.callout).foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        if store.config.panel.sections.isEmpty {
                            Text(L10n.panelNoTabs).foregroundStyle(.secondary).padding(.vertical, 12)
                        }
                        ForEach(store.config.panel.sections) { layout in
                            if let section = PanelSection(rawValue: layout.id) {
                                sectionCard(layout, section: section).frame(width: cardWidth)
                            }
                        }
                    }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 2)
                }
                .fixedSize(horizontal: false, vertical: true)
                .scrollBounceBehavior(.basedOnSize)
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { cardsViewportWidth = $0 }
                Button(L10n.panelAddTab, systemImage: "plus") { tabDraft = PanelTabDraft() }
                moduleCatalogue
                Text(L10n.panelVisibilityHelp).font(.callout).foregroundStyle(.secondary)
                Form {
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
                    Section {
                        Button(L10n.panelRestoreLayout) { store.updatePanel { $0.restoreStandardLayout() } }
                    }
                }.formStyle(.grouped).scrollDisabled(true).fixedSize(horizontal: false, vertical: true)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.navigationTitle(L10n.deckPanel)
        .sheet(item: $tabDraft) { draft in
            PanelTabEditor(draft: draft) { name, icon in
                store.updatePanel {
                    if let section = draft.section { $0.renameSection(section, name: name, icon: icon) }
                    else { $0.addSection(name: name, icon: icon) }
                }
            }
        }
    }

    private func sectionCard(_ layout: PanelSectionLayout, section: PanelSection) -> some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                Label(layout.title, systemImage: layout.symbol).fontWeight(.medium).lineLimit(1)
                    .draggable(PanelDragItem(kind: .section, id: section.rawValue))
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
                .dropDestination(for: PanelDragItem.self) { items, _ in
                    guard let item = items.first, item.kind == .section,
                          let source = PanelSection(rawValue: item.id) else { return false }
                    store.updatePanel { $0.moveSection(source, before: section) }; return true
                }
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
        }.font(.callout).labelStyle(PanelRowLabelStyle()).padding(8)
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
                guard let source = PanelSection(rawValue: item.id) else { return false }
                store.updatePanel { $0.moveSection(source, after: section) }
            }
            return true
        } isTargeted: { targeted in
            if targeted { targetedSection = section.rawValue }
            else if targetedSection == section.rawValue { targetedSection = nil }
        }
    }

    private var moduleCatalogue: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.panelAvailableModules).font(.headline)
            if store.config.panel.availableModules.isEmpty {
                Text(L10n.panelAllModulesAdded).font(.callout).foregroundStyle(.secondary)
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
            if targeted { targetedModule = module.rawValue }
            else if targetedModule == module.rawValue { targetedModule = nil }
        }
    }
}
