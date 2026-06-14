import SwiftUI

/// Chain editor: name, steps (drag-and-drop order, add/remove), stopOnError.
struct ChainEditorView: View {
    @Environment(CommandStore.self) private var store
    @Environment(AppModel.self) private var appModel

    let chain: Chain

    @State private var draft: Chain
    @State private var confirmDelete = false
    /// Terminal launch mode — shared across commands and chains.
    @AppStorage("terminalLaunchMode") private var terminalMode = TerminalLaunchMode.window.rawValue

    init(chain: Chain) {
        self.chain = chain
        _draft = State(initialValue: chain)
    }

    var body: some View {
        // List (not Form): drag-reordering (.onMove) only works in a List.
        List {
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
            }

            Section(L10n.stepsSection) {
                if draft.commandIDs.isEmpty {
                    Text(L10n.noSteps).foregroundStyle(.secondary)
                }
                ForEach(Array(draft.commandIDs.enumerated()), id: \.offset) { index, commandID in
                    HStack {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                        Text(store.commandsByID[commandID]?.name ?? L10n.deletedCommand)
                        Spacer()
                        Button(role: .destructive) {
                            if draft.commandIDs.indices.contains(index) {
                                draft.commandIDs.remove(at: index)
                            }
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                        .help(L10n.removeStep)
                    }
                }
                .onMove { draft.commandIDs.move(fromOffsets: $0, toOffset: $1) }
                .onDelete { draft.commandIDs.remove(atOffsets: $0) }

                Menu(L10n.addStep) {
                    ForEach(store.config.commands) { command in
                        Button(command.name.isEmpty ? L10n.untitled : command.name) {
                            draft.commandIDs.append(command.id)
                        }
                    }
                }
            }
        }
        // Launching happens from the popover/list; here only explicit "Delete" (with confirmation)
        // and "Save" (enabled only when there are unsaved changes).
        .toolbar {
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
