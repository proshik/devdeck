import SwiftUI
import UniformTypeIdentifiers

/// Chain editor: name, steps (drag-and-drop order, add/remove), stopOnError.
struct ChainEditorView: View {
    @Environment(CommandStore.self) private var store
    @Environment(AppModel.self) private var appModel

    let chain: Chain

    @State private var draft: Chain
    @State private var confirmDelete = false
    /// The step being dragged, while a drag is in flight.
    @State private var stepDrag: ChainStepDrag?
    /// Terminal launch mode — shared across commands and chains.
    @AppStorage("terminalLaunchMode") private var terminalMode = TerminalLaunchMode.window.rawValue

    init(chain: Chain) {
        self.chain = chain
        _draft = State(initialValue: chain)
    }

    var body: some View {
        Form {
            Section(L10n.chainSection) {
                TextField(L10n.name, text: $draft.name)
                Toggle(L10n.stopOnErrorToggle, isOn: $draft.stopOnError)
                Toggle(L10n.chainInOneTabToggle, isOn: $draft.openInTerminal)
                if draft.openInTerminal {
                    Picker(L10n.terminalModePicker, selection: $terminalMode) {
                        Text(L10n.terminalWindow).tag(TerminalLaunchMode.window.rawValue)
                        Text(L10n.terminalTab).tag(TerminalLaunchMode.tab.rawValue)
                    }
                }
                Toggle(L10n.allowFromShortcutsToggle, isOn: $draft.allowAutomation)
            }

            Section(L10n.stepsSection) {
                if draft.commandIDs.isEmpty {
                    Text(L10n.noSteps).foregroundStyle(.secondary)
                }
                ForEach(Array(draft.commandIDs.enumerated()), id: \.offset) { index, commandID in
                    ChainStepRow(
                        title: store.commandsByID[commandID]?.name ?? L10n.deletedCommand,
                        index: index,
                        count: draft.commandIDs.count,
                        drag: $stepDrag,
                        onRemove: {
                            if draft.commandIDs.indices.contains(index) {
                                draft.commandIDs.remove(at: index)
                            }
                        },
                        onMove: { source, gap in
                            draft.commandIDs = ChainStepReorder.moving(draft.commandIDs, from: source, toGap: gap)
                        }
                    )
                }

                FormActionRow {
                    Menu(L10n.addStep) {
                        ForEach(store.config.commands) { command in
                            Button(command.name.isEmpty ? L10n.untitled : command.name) {
                                draft.commandIDs.append(command.id)
                            }
                        }
                    }
                    .fixedSize()
                }
            }
        }
        .formStyle(.grouped)
        // Launching happens from the popover/list; here only explicit "Delete" (with confirmation)
        // and "Save" (enabled only when there are unsaved changes).
        // Only while the editor is the visible tab: `EditorWithLog` keeps it mounted under the log.
        .toolbar {
            if appModel.detailTab == .editor {
                ToolbarItemGroup {
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label(L10n.delete, systemImage: "trash")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.red)
                    }
                    .help(L10n.deleteChainHelp)

                    Button { save() } label: {
                        Label(hasChanges ? L10n.save : L10n.saved, systemImage: hasChanges ? "checkmark.circle.fill" : "checkmark")
                            .labelStyle(.titleAndIcon)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!hasChanges)
                    .keyboardShortcut("s")
                    .help(L10n.saveHelp)
                }
            }
        }
        .confirmationDialog(L10n.deleteChainTitle(chain.name), isPresented: $confirmDelete) {
            Button(L10n.delete, role: .destructive) {
                store.delete(chainID: chain.id)
                appModel.selection = nil
            }
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(L10n.deleteChainMessage)
        }
    }

    private var hasChanges: Bool { draft != chain }

    private func save() {
        store.upsert(draft)
    }
}

/// A step drag in flight: which step, the token its pasteboard item carries (so a drop of
/// someone else's text, or a drag that ended outside the editor, never reorders anything), and the
/// gap it would land in right now (nil — no insertion line).
private struct ChainStepDrag: Equatable {
    let source: Int
    let token: String
    var gap: Int?
}

/// One step of the chain: drag it by the row to reorder (a `Form` ignores `.onMove`, so the rows
/// carry their own drag and drop), "−" removes it.
private struct ChainStepRow: View {
    let title: String
    let index: Int
    let count: Int
    @Binding var drag: ChainStepDrag?
    let onRemove: () -> Void
    let onMove: (_ source: Int, _ gap: Int) -> Void

    @State private var height: CGFloat = 0

    /// The vertical inset of a grouped-Form row. The drop area grows by it so the whole row,
    /// up to the separators, takes the drop, and the insertion line sits on the separator.
    private static let rowInset: CGFloat = 10

    var body: some View {
        HStack {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Text(title)
            Spacer()
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless).controlHoverFeedback()
            .foregroundStyle(.secondary)
            .help(L10n.removeStep)
        }
        .padding(.vertical, Self.rowInset)
        .contentShape(Rectangle())
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
        .onDrag {
            let token = UUID().uuidString
            drag = ChainStepDrag(source: index, token: token)
            // Visible to this process only: a step dragged out to another app drops nothing there.
            let provider = NSItemProvider()
            provider.registerDataRepresentation(forTypeIdentifier: UTType.plainText.identifier,
                                                visibility: .ownProcess) { completion in
                completion(Data(token.utf8), nil)
                return nil
            }
            return provider
        }
        .onDrop(of: [.plainText], delegate: ChainStepDropDelegate(
            row: index, rowHeight: height, count: count, drag: $drag, onMove: onMove))
        .overlay(alignment: .top) {
            if drag?.gap == index { insertionLine.offset(y: -1) }
        }
        .overlay(alignment: .bottom) {
            if index == count - 1, drag?.gap == count { insertionLine.offset(y: 1) }
        }
        .padding(.vertical, -Self.rowInset)
    }

    private var insertionLine: some View {
        Capsule().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false)
    }
}

private struct ChainStepDropDelegate: DropDelegate {
    let row: Int
    let rowHeight: CGFloat
    let count: Int
    @Binding var drag: ChainStepDrag?
    let onMove: (_ source: Int, _ gap: Int) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        drag != nil && info.hasItemsConforming(to: [.plainText])
    }

    func dropEntered(info: DropInfo) { updateGap(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateGap(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        drag?.gap = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let current = drag else { return false }
        drag = nil
        guard let gap = current.gap,
              let provider = info.itemProviders(for: [.plainText]).first else { return false }
        _ = provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, _ in
            guard let data, String(decoding: data, as: UTF8.self) == current.token else { return }
            DispatchQueue.main.async { onMove(current.source, gap) }
        }
        return true
    }

    private func updateGap(_ info: DropInfo) {
        guard let source = drag?.source else { return }
        let gap = ChainStepReorder.gap(overRow: row, y: info.location.y, rowHeight: rowHeight)
        drag?.gap = ChainStepReorder.effectiveGap(source: source, gap: gap, count: count)
    }
}
