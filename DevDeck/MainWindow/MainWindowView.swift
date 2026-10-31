import SwiftUI

/// Stable navigation; commands and chains have their own list beside the editor and logs.
struct MainWindowView: View {
    @Environment(CommandStore.self) private var store
    @Environment(AppModel.self) private var appModel

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                Section(L10n.settings) {
                    navigationRow(L10n.deckGeneral, icon: "gearshape", selection: .settings)
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
            detail
        }
        // Reserve room for the sidebar at its maximum width and three complete tab cards.
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
        case .panel:
            PanelSettingsView()
        case .updates:
            UpdatesView()
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
            VStack(spacing: 0) {
                List(selection: commandSelection) {
                    if store.config.commands.isEmpty && store.config.chains.isEmpty {
                        Text(L10n.noCommandsYet).foregroundStyle(.secondary)
                    }
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
                                    }
                            }.onMove { store.moveChains($0, to: $1) }
                        }
                    }
                }
                Divider()
                Menu {
                    Button(L10n.newCommand) { addCommand() }
                    Button(L10n.newDaemon) { addCommand(daemon: true) }
                    Button(L10n.newChain) { addChain() }
                } label: { Label(L10n.deckAdd, systemImage: "plus") }
                    .fixedSize().padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }.frame(minWidth: 190, idealWidth: 230, maxWidth: 300)
            commandDetail.frame(minWidth: 350, maxWidth: .infinity, maxHeight: .infinity)
        }.navigationTitle(L10n.deckCommands)
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

    private func navigationRow(_ title: String, icon: String, selection: MainSelection) -> some View {
        Label(title, systemImage: icon).tag(selection)
    }

    private var portForwards: some View {
        List {
            let ports = store.config.commands.filter { $0.port != nil }
            if ports.isEmpty {
                Text(L10n.deckNoPortForwards).foregroundStyle(.secondary)
            }
            ForEach(ports) { command in
                Button {
                    appModel.selection = .command(command.id)
                } label: {
                    HStack {
                        Label(command.name, systemImage: "arrow.left.arrow.right")
                        Spacer()
                        if let port = command.port { Text(String(port)).monospacedDigit().foregroundStyle(.secondary) }
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }.buttonStyle(.plain).controlHoverFeedback()
            }
        }.navigationTitle(L10n.deckPorts)
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

    private func duplicateChain(_ id: UUID) {
        guard let copyID = store.duplicate(chainID: id) else { return }
        appModel.detailTab = .editor
        appModel.selection = .chain(copyID)
    }
}

/// Command detail: "Command" (editor) and "Logs" tabs.
struct CommandDetailView: View {
    let command: Command
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        TabView(selection: $appModel.detailTab) {
            CommandEditorView(command: command)
                .tabItem { Label(L10n.commandTab, systemImage: "slider.horizontal.3") }
                .tag(DetailTab.editor)
            LogView(id: command.id)
                .tabItem { Label(L10n.logs, systemImage: "list.bullet.rectangle") }
                .tag(DetailTab.logs)
        }
        .padding()
    }
}

/// Chain detail: "Chain" (editor) and "Logs" tabs.
struct ChainDetailView: View {
    let chain: Chain
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
        TabView(selection: $appModel.detailTab) {
            ChainEditorView(chain: chain)
                .tabItem { Label(L10n.chainTab, systemImage: "slider.horizontal.3") }
                .tag(DetailTab.editor)
            LogView(id: chain.id)
                .tabItem { Label(L10n.logs, systemImage: "list.bullet.rectangle") }
                .tag(DetailTab.logs)
        }
        .padding()
    }
}
