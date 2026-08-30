import SwiftUI

/// Main window: command/chain list on the left, editor + logs for the selected item on the right.
struct MainWindowView: View {
    @Environment(CommandStore.self) private var store
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel

        NavigationSplitView {
            // Row order = order in the menu bar popover; dragging persists it to config.json.
            List(selection: $appModel.selection) {
                Section(L10n.commands) {
                    ForEach(commands) { command in
                        sidebarRow(command, icon: "terminal")
                    }
                    .onMove { store.moveCommands($0, to: $1, daemons: false) }
                }
                Section(L10n.daemons) {
                    ForEach(daemons) { command in
                        sidebarRow(command, icon: "infinity")
                    }
                    .onMove { store.moveCommands($0, to: $1, daemons: true) }
                }
                Section(L10n.chains) {
                    ForEach(store.config.chains) { chain in
                        Label(chain.name.isEmpty ? L10n.untitled : chain.name, systemImage: "link")
                            .tag(MainSelection.chain(chain.id))
                            .contextMenu {
                                Button(L10n.duplicate) { duplicateChain(chain.id) }
                            }
                    }
                    .onMove { store.moveChains($0, to: $1) }
                }
            }
            .frame(minWidth: 220)
            // Settings pinned to the bottom of the sidebar — always visible, separated from the
            // scrolling commands/daemons/chains list.
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 0) {
                    Divider()
                    VStack(spacing: 2) {
                        pinnedButton(L10n.proxy, icon: "network", selection: .proxy)
                        pinnedButton(L10n.cleanup, icon: "trash", selection: .cleanup)
                        pinnedButton(L10n.claudeTabsSection, icon: "macwindow.on.rectangle", selection: .claudeTabs)
                        pinnedButton(L10n.settings, icon: "gearshape", selection: .settings)
                    }
                    .padding(8)
                }
                .background(.bar)
            }
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button(L10n.newCommand) { addCommand() }
                        Button(L10n.newDaemon) { addCommand(daemon: true) }
                        Button(L10n.newChain) { addChain() }
                    } label: { Image(systemName: "plus") }
                }
            }
        } detail: {
            detail
        }
        .frame(minWidth: 760, minHeight: 480)
        // The sidebar's toolbar makes AppKit draw its titlebar separator, which on macOS 26 lands
        // across the traffic lights. Nothing here is separated by it — the sidebar has its own
        // divider above the pinned buttons.
        .background(WindowAccessor { $0.titlebarSeparatorStyle = .none })
    }

    @ViewBuilder
    private var detail: some View {
        switch appModel.selection {
        case .command(let id):
            if let command = store.commandsByID[id] {
                CommandDetailView(command: command).id(id)
            } else {
                placeholder
            }
        case .chain(let id):
            if let chain = store.config.chains.first(where: { $0.id == id }) {
                ChainDetailView(chain: chain).id(id)
            } else {
                placeholder
            }
        case .settings:
            SettingsView()
        case .proxy:
            ProxyShareEditorView(share: store.config.proxy)
        case .cleanup:
            CleanupView()
        case .claudeTabs:
            ClaudeTabsView()
        case nil:
            placeholder
        }
    }

    private var placeholder: some View {
        Text(L10n.selectPlaceholder)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var commands: [Command] { store.config.commands.filter { !$0.isDaemon } }
    private var daemons: [Command] { store.config.commands.filter(\.isDaemon) }

    private func sidebarRow(_ command: Command, icon: String) -> some View {
        Label(command.name.isEmpty ? L10n.untitled : command.name, systemImage: icon)
            .tag(MainSelection.command(command.id))
            .contextMenu {
                Button(L10n.duplicate) { duplicateCommand(command.id) }
            }
    }

    /// Pinned sidebar entry (Proxy / Settings) styled to mimic a selected sidebar row.
    private func pinnedButton(_ title: String, icon: String, selection: MainSelection) -> some View {
        let selected = appModel.selection == selection
        return Button {
            appModel.selection = selection
        } label: {
            Label(title, systemImage: icon)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 5)
                .padding(.horizontal, 8)
                .contentShape(Rectangle())
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(selected ? Color.accentColor.opacity(0.22) : .clear)
                )
        }
        .buttonStyle(.plain)
    }

    private func addCommand(daemon: Bool = false) {
        let command = Command(id: UUID(), name: daemon ? L10n.newDaemon : L10n.newCommand,
                              command: "", isDaemon: daemon)
        store.upsert(command)
        appModel.selection = .command(command.id)
    }

    private func addChain() {
        let chain = Chain(id: UUID(), name: L10n.newChain, commandIDs: [])
        store.upsert(chain)
        appModel.selection = .chain(chain.id)
    }

    /// Selection follows the copy, which opens its editor — the same move `addCommand` makes, and
    /// the copy's name is the first thing worth changing. A `nil` id means the original was deleted
    /// from under us; leave the selection alone.
    private func duplicateCommand(_ id: UUID) {
        guard let copyID = store.duplicate(commandID: id) else { return }
        appModel.selection = .command(copyID)
    }

    private func duplicateChain(_ id: UUID) {
        guard let copyID = store.duplicate(chainID: id) else { return }
        appModel.selection = .chain(copyID)
    }
}

/// Command detail: "Command" (editor) and "Logs" tabs.
struct CommandDetailView: View {
    let command: Command

    var body: some View {
        TabView {
            CommandEditorView(command: command)
                .tabItem { Label(L10n.commandTab, systemImage: "slider.horizontal.3") }
            LogView(id: command.id)
                .tabItem { Label(L10n.logs, systemImage: "list.bullet.rectangle") }
        }
        .padding()
    }
}

/// Chain detail: "Chain" (editor) and "Logs" tabs.
struct ChainDetailView: View {
    let chain: Chain

    var body: some View {
        TabView {
            ChainEditorView(chain: chain)
                .tabItem { Label(L10n.chainTab, systemImage: "slider.horizontal.3") }
            LogView(id: chain.id)
                .tabItem { Label(L10n.logs, systemImage: "list.bullet.rectangle") }
        }
        .padding()
    }
}
