import SwiftUI

/// Stable navigation; commands and chains have their own list beside the editor and logs.
struct MainWindowView: View {
    @Environment(CommandStore.self) private var store
    @Environment(AppModel.self) private var appModel
    @Environment(PermissionsModel.self) private var permissions
    @Environment(RecoveryModel.self) private var recovery: RecoveryModel?
    /// The command or chain whose "Delete…" from the inner list awaits confirmation.
    @State private var pendingDeletion: MainSelection?

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Section(L10n.settings) {
                    navigationRow(L10n.deckGeneral, icon: "gearshape", selection: .settings)
                    navigationRow(L10n.permissionsTitle, icon: "lock.shield", selection: .permissions)
                    navigationRow(L10n.deckPanel, icon: "square.grid.2x2", selection: .panel)
                    navigationRow(L10n.deckUpdates, icon: "arrow.down.circle", selection: .updates)
                }
                Section(L10n.deckEnvironment) {
                    navigationRow(L10n.deckCommands, icon: "terminal", selection: .commands)
                    navigationRow(L10n.deckPorts, icon: "arrow.left.arrow.right", selection: .ports)
                    navigationRow(L10n.proxy, icon: "network", selection: .proxy)
                    navigationRow(L10n.claudeTabsSection, icon: "macwindow", selection: .claudeTabs)
                    navigationRow(L10n.cleanup, icon: "trash", selection: .cleanup)
                }
                Section(L10n.deckObservation) {
                    navigationRow(L10n.networkTitle, icon: "network", selection: .network)
                    navigationRow(L10n.deckThisMac, icon: "waveform.path.ecg", selection: .monitoring)
                    navigationRow(L10n.deckContainers, icon: "shippingbox", selection: .containers)
                    navigationRow(L10n.deckEnergy, icon: "battery.100percent", selection: .energy)
                }
                Section(L10n.deckMacTools) {
                    navigationRow(L10n.deckDisplays, icon: "display", selection: .displays)
                    navigationRow(L10n.clipboardTitle, icon: "clipboard", selection: .clipboard)
                    navigationRow(L10n.awakeTitle, icon: "cup.and.saucer", selection: .awake)
                }
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 290)
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
            // The banner takes its own place above the page rather than a safe-area inset: the
            // panes of an `HSplitView` (commands, clipboard) are AppKit-hosted, ignore SwiftUI
            // insets and would draw under it. Without the banner the page stays the column's root,
            // so its scroll view still runs under the toolbar.
            if let recovery, recovery.hasSuspensions, appModel.selection != .permissions {
                VStack(spacing: 0) {
                    RecoveryBanner(model: recovery) { appModel.selection = .permissions }
                        .padding(.horizontal, 20).padding(.top, 12)
                    detail.frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                detail
            }
        }
        // Reserve room for the sidebar at its maximum width next to a full-width settings form.
        .frame(minWidth: 1040, minHeight: 580)
        // The sidebar's toolbar makes AppKit draw its titlebar separator, which on macOS 26 lands
        // across the traffic lights. The sidebar already has its native separation.
        .background(WindowAccessor {
            $0.titlebarSeparatorStyle = .none
            $0.hidesOnDeactivate = false
            appModel.mainWindowActivation.track($0)
        })
    }

    @ViewBuilder
    private var detail: some View {
        switch appModel.selection {
        case .commands, .command, .chain:
            commandWorkspace
        case .settings:
            SettingsView()
        case .permissions:
            PermissionsView(model: permissions, recovery: recovery)
        case .panel:
            PanelSettingsView()
        case .updates:
            UpdatesView()
        case .network:
            NetworkPage()
        case .monitoring:
            MonitoringPage(section: .mac)
        case .containers:
            MonitoringPage(section: .containers)
        case .energy:
            MonitoringPage(section: .energy)
        case .awake:
            AwakeSettingsView()
        case .displays:
            DisplayBrightnessSettingsView()
        case .clipboard:
            ClipboardView()
        case .ports:
            portForwards
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

    // Keep the workspace selected in the sidebar when a command is selected in its inner list.
    // Binding the sidebar directly to that command would leave it without a matching row.
    private var sidebarSelection: Binding<MainSelection?> {
        Binding(get: {
            switch appModel.selection {
            case .command, .chain: .commands
            default: appModel.selection
            }
        }, set: { if let selection = $0 { appModel.selection = selection } })
    }

    private var commandSelection: Binding<MainSelection?> {
        Binding(get: {
            switch appModel.selection {
            case .command, .chain: appModel.selection
            default: nil
            }
        }, set: { if let selection = $0 { appModel.selection = selection } })
    }

    private var commandWorkspace: some View {
        HSplitView {
            List(selection: commandSelection) {
                if !commands.isEmpty {
                    Section(L10n.commands) {
                        ForEach(commands) { sidebarRow($0, icon: "terminal") }
                            .onMove { store.moveCommands($0, to: $1, daemons: false) }
                    }
                }
                if !daemons.isEmpty {
                    Section(L10n.daemons) {
                        ForEach(daemons) { sidebarRow($0, icon: "infinity") }
                            .onMove { store.moveCommands($0, to: $1, daemons: true) }
                    }
                }
                if !store.config.chains.isEmpty {
                    Section(L10n.chains) {
                        ForEach(store.config.chains) { chain in
                            Label(chain.name.isEmpty ? L10n.untitled : chain.name, systemImage: "link")
                                .tag(MainSelection.chain(chain.id))
                                .contextMenu {
                                    Button(L10n.duplicate) { duplicateChain(chain.id) }
                                    Divider()
                                    Button("\(L10n.delete)…", role: .destructive) {
                                        pendingDeletion = .chain(chain.id)
                                    }
                                }
                        }.onMove { store.moveChains($0, to: $1) }
                    }
                }
            }
            // The same look as the window's sidebar next to it; adding lives in its "+" menu.
            .listStyle(.sidebar)
            .overlay {
                if store.config.commands.isEmpty && store.config.chains.isEmpty {
                    // No icon of its own: the placeholder beside it already carries one.
                    ContentUnavailableView {} description: { Text(L10n.noCommandsYet) }
                }
            }
            .frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
            commandDetail.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        }
        .besideFloatingSidebar()
        .navigationTitle(L10n.deckCommands)
        // The same confirmation as the editor's toolbar "Delete".
        .confirmationDialog(deletionTitle, isPresented: Binding(
            get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }
        ), presenting: pendingDeletion) { item in
            Button(L10n.delete, role: .destructive) { delete(item) }
            Button(L10n.cancel, role: .cancel) {}
        } message: { item in
            if case .chain = item { Text(L10n.deleteChainMessage) } else { Text(L10n.deleteCommandMessage) }
        }
    }

    @ViewBuilder private var commandDetail: some View {
        switch appModel.selection {
        case .command(let id):
            if let command = store.commandsByID[id] {
                CommandDetailView(command: command).id(id)
            } else { placeholder }
        case .chain(let id):
            if let chain = store.config.chains.first(where: { $0.id == id }) {
                ChainDetailView(chain: chain).id(id)
            } else { placeholder }
        default: placeholder
        }
    }

    private var placeholder: some View {
        // A sentence, not a title: it reads as a hint under the icon rather than a headline.
        ContentUnavailableView {
            Image(systemName: "terminal")
        } description: {
            Text(L10n.selectPlaceholder)
        }
    }

    private var commands: [Command] { store.config.commands.filter { !$0.isDaemon } }
    private var daemons: [Command] { store.config.commands.filter(\.isDaemon) }

    private func sidebarRow(_ command: Command, icon: String) -> some View {
        Label(command.name.isEmpty ? L10n.untitled : command.name, systemImage: icon)
            .tag(MainSelection.command(command.id))
            .contextMenu {
                Button(L10n.duplicate) { duplicateCommand(command.id) }
                Divider()
                Button("\(L10n.delete)…", role: .destructive) { pendingDeletion = .command(command.id) }
            }
    }

    private func navigationRow(_ title: String, icon: String, selection: MainSelection) -> some View {
        Label(title, systemImage: icon).tag(selection)
    }

    private var portForwards: some View {
        let ports = store.config.commands.filter { $0.port != nil }
        return Group {
            if ports.isEmpty {
                ContentUnavailableView(L10n.deckNoPortForwards, systemImage: "arrow.left.arrow.right")
            } else {
                Form {
                    Section {
                        ForEach(ports) { command in
                            FormNavigationRow(title: command.name.isEmpty ? L10n.untitled : command.name,
                                              icon: "arrow.left.arrow.right",
                                              value: command.port.map { String($0) }) {
                                appModel.selection = .command(command.id)
                            }
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle(L10n.deckPorts)
    }

    private func addCommand(daemon: Bool = false) {
        appModel.detailTab = .editor
        let command = Command(id: UUID(), name: daemon ? L10n.newDaemon : L10n.newCommand,
                              command: "", isDaemon: daemon)
        store.upsert(command)
        appModel.selection = .command(command.id)
    }

    private func addChain() {
        appModel.detailTab = .editor
        let chain = Chain(id: UUID(), name: L10n.newChain, commandIDs: [])
        store.upsert(chain)
        appModel.selection = .chain(chain.id)
    }

    /// Selection follows the copy, which opens its editor — the same move `addCommand` makes, and
    /// the copy's name is the first thing worth changing. A `nil` id means the original was deleted
    /// from under us; leave the selection alone.
    private func duplicateCommand(_ id: UUID) {
        guard let copyID = store.duplicate(commandID: id) else { return }
        appModel.detailTab = .editor
        appModel.selection = .command(copyID)
    }

    private var deletionTitle: String {
        switch pendingDeletion {
        case .command(let id): L10n.deleteCommandTitle(store.commandsByID[id]?.name ?? "")
        case .chain(let id): L10n.deleteChainTitle(store.config.chains.first { $0.id == id }?.name ?? "")
        default: ""
        }
    }

    /// The editor's toolbar "Delete" does the same: the store call, then, if the deleted item was
    /// open, back to the workspace's list.
    private func delete(_ item: MainSelection) {
        switch item {
        case .command(let id): store.delete(commandID: id)
        case .chain(let id): store.delete(chainID: id)
        default: return
        }
        if appModel.selection == item { appModel.selection = .commands }
    }

    private func duplicateChain(_ id: UUID) {
        guard let copyID = store.duplicate(chainID: id) else { return }
        appModel.detailTab = .editor
        appModel.selection = .chain(copyID)
    }
}

extension View {
    /// For an `HSplitView` page in the window's detail column. The split view runs under the
    /// floating sidebar, so its first pane's minimum already counts the sidebar's width; SwiftUI
    /// measures that minimum for the area beside the sidebar and so counts the sidebar twice.
    /// Once the doubled minimum exceeds the window (on the commands page, past a sidebar of about
    /// 250 pt), the whole `NavigationSplitView` is laid out wider than the window and centred, which
    /// cuts off the sidebar's leading part. Not reporting the minimum keeps the column within the
    /// window (the window's minimum width leaves room for both panes beside the widest sidebar),
    /// and leading alignment keeps the split view from being centred on the doubled width.
    func besideFloatingSidebar() -> some View {
        frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    }
}

/// Command detail: "Command" (editor) and "Logs", switched in the window toolbar.
struct CommandDetailView: View {
    let command: Command

    var body: some View {
        EditorWithLog(editorTitle: L10n.commandTab, logID: command.id) {
            CommandEditorView(command: command)
        }
    }
}

/// Chain detail: "Chain" (editor) and "Logs", switched in the window toolbar.
struct ChainDetailView: View {
    let chain: Chain

    var body: some View {
        EditorWithLog(editorTitle: L10n.chainTab, logID: chain.id) {
            ChainEditorView(chain: chain)
        }
    }
}

/// An editor and its run log on one page, switched by a segmented control in the window toolbar
/// through `AppModel.detailTab` — which adding, duplicating and the popover's "Logs" link also set.
/// The editor stays mounted, only hidden, while the log is shown: its unsaved draft lives in the
/// editor's own state, and switching to the log must not throw it away. The editor shows its own
/// toolbar actions only while it is the visible tab.
private struct EditorWithLog<Editor: View>: View {
    let editorTitle: String
    let logID: UUID
    @ViewBuilder let editor: Editor
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        let showsLog = appModel.detailTab == .logs
        ZStack {
            editor
                .opacity(showsLog ? 0 : 1)
                .disabled(showsLog)
                .allowsHitTesting(!showsLog)
                .accessibilityHidden(showsLog)
            if showsLog { LogView(id: logID) }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker(editorTitle, selection: $appModel.detailTab) {
                    Text(editorTitle).tag(DetailTab.editor)
                    Text(L10n.logs).tag(DetailTab.logs)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
    }
}
