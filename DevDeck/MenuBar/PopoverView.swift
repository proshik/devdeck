import SwiftUI

/// Native compact control panel backed by the existing process and settings models.
struct PopoverView: View {
    @Environment(CommandStore.self) private var store
    @Environment(ProcessManager.self) private var manager
    @Environment(AppModel.self) private var appModel
    @Environment(UpdateController.self) private var updates
    @Environment(ProxyManager.self) private var proxy
    @Environment(AwakeModel.self) private var awake
    @Environment(\.openWindow) private var openWindow
    @State private var contentHeight: CGFloat = 1

    @AppStorage("popover.section.commands.collapsed") private var commandsCollapsed = false
    @AppStorage("popover.section.daemons.collapsed") private var daemonsCollapsed = false
    @AppStorage("popover.section.chains.collapsed") private var chainsCollapsed = false
    @AppStorage("popover.section.ports.collapsed") private var portsCollapsed = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("DevDeck").font(.headline)
                Spacer(minLength: 12)
                Button { openItem(.settings) } label: {
                    Label(L10n.deckSettings, systemImage: "gearshape")
                        .labelStyle(.iconOnly).frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless).controlHoverFeedback()
                .foregroundStyle(updates.updateAvailable || diskNeedsCleanup ? Color.orange : Color.primary)
                .help(updates.updateAvailable ? L10n.updateAvailableHelp(updates.latestVersion ?? "")
                      : diskNeedsCleanup ? L10n.cleanupHelp : L10n.settings)
            }.padding(.horizontal, 16).padding(.vertical, 8)
            if !store.config.panel.visibleSections.isEmpty {
                PanelSectionTabs(selection: Binding(
                    get: { selectedSection ?? .environment },
                    set: { section in
                        appModel.panelSection = section
                        store.updatePanel { $0.lastSection = section.rawValue }
                    }
                ), sections: store.config.panel.visibleSectionLayouts)
                    .frame(maxWidth: .infinity).padding(.horizontal, 16).padding(.bottom, 12)
            }
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if let error = store.error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.red)
                            .padding(16)
                    }
                    if let section = selectedSection {
                        if section == .environment && store.config.panel.showMemoryInEnvironment { memoryRow }
                        ForEach(store.config.panel.visibleModules(in: section)) { module in
                            moduleContent(module).contextMenu { PanelModuleMenu(module: module) }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(L10n.panelEmpty).foregroundStyle(.secondary)
                            Button(L10n.deckPanelSettings) { openItem(.panel) }
                        }.padding(16)
                    }
                    hiddenActivity
                }
                .padding(.bottom, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
                .onGeometryChange(for: CGFloat.self) { ceil($0.size.height) } action: {
                    if contentHeight != $0 { contentHeight = $0 }
                }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, appModel.panelContentHeightLimit))
        }
        .font(.body)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(.background)
        .onChange(of: store.config.panel) { _, panel in
            if let resolved = panel.resolvedSection(preferred: appModel.panelSection) { appModel.panelSection = resolved }
        }
    }

    private var selectedSection: PanelSection? {
        store.config.panel.resolvedSection(preferred: appModel.panelSection)
    }

    @ViewBuilder private func moduleContent(_ module: PanelModuleID) -> some View {
        switch module {
        case .commands:
            if commands.isEmpty {
                HStack(spacing: 8) {
                    Text(L10n.noCommandsYet).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    detailsButton(module)
                }.padding(.horizontal, 16).padding(.vertical, 10)
            } else {
                CollapsibleSection(title: L10n.commands, count: commands.count,
                                   runningCount: runningCommandsCount, collapsed: $commandsCollapsed) {
                    ForEach(commands) { commandRow($0) }
                }
            }
        case .daemons:
            if !daemons.isEmpty {
                CollapsibleSection(title: L10n.daemons, count: daemons.count,
                                   runningCount: aliveDaemonsCount, collapsed: $daemonsCollapsed) {
                    ForEach(daemons) { commandRow($0) }
                }
            } else { emptyModule(module) }
        case .chains:
            if !store.config.chains.isEmpty {
                CollapsibleSection(title: L10n.chains, count: store.config.chains.count,
                                   runningCount: runningChainsCount, collapsed: $chainsCollapsed) {
                    ForEach(store.config.chains) { chainRow($0) }
                }
            } else { emptyModule(module) }
        case .portForwards:
            if !ports.isEmpty {
                CollapsibleSection(title: L10n.deckPorts, count: ports.count,
                                   runningCount: ports.filter { StatusIndicator.forCommand(manager.states[$0.id]).isStop }.count,
                                   collapsed: $portsCollapsed) {
                    ForEach(ports) { commandRow($0) }
                }
            } else { emptyModule(module) }
        case .proxy:
            if store.config.settings.proxyShareEnabled || store.config.settings.proxyDiscoveryEnabled || !store.config.remoteProxies.isEmpty {
                ProxySectionView()
            } else { emptyModule(module) }
        case .agentTabs:
            Divider().padding(.horizontal, 16)
            ClaudeTabsSectionView()
        case .mac: measurementModule(module, section: .mac)
        case .containers: measurementModule(module, section: .containers)
        case .energy: measurementModule(module, section: .energy)
        case .awake:
            AwakeSectionView()
            Button(L10n.deckDetails) { openItem(.awake) }
                .buttonStyle(.plain).controlHoverFeedback().foregroundStyle(.tint)
                .padding(.horizontal, 16).padding(.bottom, 10)
        }
    }

    private func measurementModule(_ module: PanelModuleID, section: MonitoringSection) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(module.title, systemImage: module.symbol).fontWeight(.medium)
                Spacer(minLength: 4)
                detailsButton(module)
            }
            MonitoringMetricsView(section: section)
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private func detailsButton(_ module: PanelModuleID) -> some View {
        Button { openItem(module.settingsSelection) } label: {
            Label(module.title, systemImage: "arrow.up.forward")
                .labelStyle(.iconOnly).frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless).controlHoverFeedback()
        .foregroundStyle(.secondary).help(module.title)
    }

    private func emptyModule(_ module: PanelModuleID) -> some View {
        HStack(spacing: 8) {
            Text(module.title).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(L10n.panelNoItems).font(.caption).foregroundStyle(.secondary)
            detailsButton(module)
        }.padding(.horizontal, 16).padding(.vertical, 8)
    }

    private var memoryRow: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let memory = SystemMemory.current()
            HStack {
                Label(L10n.memory, systemImage: "memorychip")
                Spacer(minLength: 4)
                Text(SystemMemory.format(usedBytes: memory.usedBytes, totalBytes: memory.totalBytes))
                    .foregroundStyle(.secondary).monospacedDigit()
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    private var activeHiddenModules: [PanelModuleID] {
        PanelActivity.activeModules(commands: store.config.commands, states: manager.states,
                                    chains: store.config.chains, chainStates: manager.chainStates,
                                    proxyActive: proxy.isAdvertising || proxy.activeProxy?.isLive == true
                                        || StatusIndicator.forCommand(manager.states[ProxyShare.daemonID]).isStop
                                        || StatusIndicator.forCommand(manager.states[RemoteProxy.bridgeDaemonID]).isStop,
                                    agentCaptureEnabled: store.config.settings.claudeTabsRestore,
                                    awakeActive: awake.isBusy)
            .filter { !store.config.panel.isShown($0) }
    }

    @ViewBuilder private var hiddenActivity: some View {
        if !activeHiddenModules.isEmpty {
            Divider().padding(.horizontal, 16)
            HStack(spacing: 8) {
                Label(L10n.panelHiddenActivity(activeHiddenModules.count), systemImage: "bolt.horizontal.circle")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                Spacer(minLength: 4)
                Menu(L10n.panelManage) {
                    ForEach(activeHiddenModules) { module in
                        Button(module.title) { openItem(module.settingsSelection) }
                    }
                }.menuStyle(.borderlessButton).fixedSize().controlHoverFeedback()
            }.padding(.horizontal, 16).padding(.vertical, 10)
        }
    }

    // MARK: splitting and counters

    /// Regular commands (not daemons).
    private var commands: [Command] { store.config.commands.filter { !$0.isDaemon && $0.port == nil } }
    /// Daemon commands (long-running).
    private var daemons: [Command] { store.config.commands.filter { $0.isDaemon && $0.port == nil } }

    private var ports: [Command] { store.config.commands.filter { $0.port != nil } }

    private var runningCommandsCount: Int {
        commands.filter { StatusIndicator.forCommand(manager.states[$0.id]).isStop }.count
    }
    private var aliveDaemonsCount: Int {
        daemons.filter { manager.states[$0.id] == .daemonRunning }.count
    }
    private var runningChainsCount: Int {
        store.config.chains.filter { StatusIndicator.forChain(manager.chainStates[$0.id]).isStop }.count
    }

    private func commandRow(_ command: Command) -> some View {
        VStack(spacing: 0) {
            DeckRow(
                name: command.name,
                needsSudo: command.needsSudo,
                indicator: StatusIndicator.forCommand(manager.states[command.id]),
                onToggle: { toggleCommand(command) },
                onLogs: { appModel.detailTab = .logs; openItem(.command(command.id)) },
                watchdog: command.isDaemon
                    ? DeckRow.WatchdogBadge(enabled: command.watchdogEnabled,
                                            phase: manager.watchdogPhases[command.id])
                    : nil,
                onWatchdogToggle: command.isDaemon ? { toggleWatchdog(command) } : nil
            )
            if command.isDaemon, let conflict = manager.portConflicts[command.id] {
                PortConflictPanel(conflict: conflict,
                                  onKill: { manager.killOccupantAndStart(command.id) },
                                  onDismiss: { manager.dismissPortConflict(command.id) })
            }
        }
    }

    private func chainRow(_ chain: Chain) -> some View {
        DeckRow(
            name: chain.name,
            needsSudo: false,
            indicator: StatusIndicator.forChain(manager.chainStates[chain.id]),
            onToggle: { toggleChain(chain) },
            onLogs: { appModel.detailTab = .logs; openItem(.chain(chain.id)) }
        )
    }

    private var diskNeedsCleanup: Bool {
        (manager.cachedVMDisk?.fraction ?? 0) >= VMDiskInfo.cleanupHintFraction
    }

    // MARK: actions

    private func toggleCommand(_ command: Command) {
        if StatusIndicator.forCommand(manager.states[command.id]).isStop {
            manager.stop(command.id)
        } else if command.promptForDirectory {
            runAfterChoosingDirectory(command)
        } else {
            manager.run(command)
        }
    }

    /// Ask where to run, then launch a copy bound to that directory — the stored command is
    /// untouched, so one "claude" serves every project.
    ///
    /// `NSApp.activate()` first: the popover is `.transient` and dismisses as soon as the panel
    /// takes focus, and without activating, the panel can open behind other windows.
    private func runAfterChoosingDirectory(_ command: Command) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.chooseRunDirectory
        // Which command is this for — the popover has already dismissed by the time the panel is up.
        panel.message = L10n.chooseRunDirectoryMessage(command.name)
        // Open near the project when the command has a stored directory, instead of wherever the
        // panel last happened to be.
        if let stored = command.workingDirectory, !stored.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: (stored as NSString).expandingTildeInPath)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        manager.run(command.withWorkingDirectory(url.path))
    }

    /// The shield button: persist the flag and arm/disarm watching. Arming an idle daemon starts it.
    private func toggleWatchdog(_ command: Command) {
        if command.watchdogEnabled {
            store.setWatchdog(false, forCommand: command.id)
            manager.disarmWatchdog(command.id)
        } else {
            store.setWatchdog(true, forCommand: command.id)
            var armed = command
            armed.watchdogEnabled = true
            manager.armWatchdog(armed)
        }
    }

    private func toggleChain(_ chain: Chain) {
        if StatusIndicator.forChain(manager.chainStates[chain.id]).isStop {
            manager.stopChain(chain.id)
        } else {
            manager.run(chain, commands: store.commandsByID)
        }
    }

    private func openItem(_ selection: MainSelection) {
        openMainWindow(selection: selection)
    }

    private func openMainWindow(selection: MainSelection? = nil) {
        appModel.showMainWindow(selection: selection) {
            openWindow(id: "main")
            NSApp.activate()
        }
    }
}

/// Collapsible deck section: a clickable uppercase header with a counter and a
/// chevron on the right. Green counter = how many are active right now; otherwise grey — total.
/// The collapse state is owned by the caller (via an @AppStorage binding).
struct CollapsibleSection<Content: View>: View {
    let title: String
    let count: Int
    let runningCount: Int
    @Binding var collapsed: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { collapsed.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(title)
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                    Text("\(runningCount > 0 ? runningCount : count)")
                        .font(.system(size: 10, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(runningCount > 0 ? Color.green : Color.secondary.opacity(0.6))
                    Spacer()
                    Image(systemName: collapsed ? "chevron.right" : "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain).controlHoverFeedback()

            if !collapsed {
                content()
            }
        }
    }
}

/// One deck row: status dot · name (· sudo lock) (· 🛡 watchdog) · ▶/■ · ☰ logs.
struct DeckRow: View {
    /// Watchdog shield state for a daemon row; nil — no shield (regular commands, chains).
    struct WatchdogBadge: Equatable {
        let enabled: Bool                            // the persisted Command.watchdogEnabled flag
        let phase: ProcessManager.WatchdogPhase?     // live phase; nil — armed but not watching now
    }

    let name: String
    let needsSudo: Bool
    let indicator: DeckIndicator
    let onToggle: () -> Void
    let onLogs: () -> Void
    var watchdog: WatchdogBadge? = nil
    var onWatchdogToggle: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            StatusDot(status: indicator.status)

            HStack(spacing: 4) {
                Text(name).lineLimit(1).truncationMode(.tail)
                if needsSudo {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 6)

            if let watchdog {
                Button(action: { onWatchdogToggle?() }) {
                    Image(systemName: watchdog.enabled ? "shield.fill" : "shield.slash")
                        .font(.system(size: 13))
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).controlHoverFeedback()
                .foregroundStyle(watchdogColor(watchdog))
                .help(watchdogHelp(watchdog))
                .accessibilityLabel(watchdogHelp(watchdog) + " " + name)
            }

            Button(action: onToggle) {
                Image(systemName: indicator.isStop ? "stop.fill" : "play.fill")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)        // large tap target
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).controlHoverFeedback()
            .foregroundStyle(indicator.isStop ? Color.red : Color.green)
            .help(indicator.isStop ? L10n.stop : L10n.run)
            .accessibilityLabel((indicator.isStop ? L10n.stop : L10n.run) + " " + name)

            Button(action: onLogs) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 12))
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).controlHoverFeedback()
            .foregroundStyle(.secondary)
            .help(L10n.logs)
            .accessibilityLabel(L10n.logs + " " + name)
        }
        .font(.system(size: 13))
        .padding(.leading, 16)
        .padding(.trailing, 16)   // right gap: the scrollbar "slider" won't overlap the buttons
        .padding(.vertical, 2)
        .contentShape(Rectangle())
    }

    private func watchdogColor(_ badge: WatchdogBadge) -> Color {
        guard badge.enabled else { return Color(white: 0.72) }
        switch badge.phase {
        case .armed: return .green
        case .restarting: return .orange
        case .pausedOnConflict: return .yellow
        case .gaveUp: return .red
        case nil: return .secondary   // flag on, but not watching until the next start
        }
    }

    private func watchdogHelp(_ badge: WatchdogBadge) -> String {
        guard badge.enabled else { return L10n.watchdogEnableHelp }
        switch badge.phase {
        case .restarting(let attempt): return L10n.watchdogRestartingHelp(attempt)
        case .pausedOnConflict: return L10n.watchdogPausedHelp
        case .gaveUp: return L10n.watchdogGaveUpHelp
        case .armed, nil: return L10n.watchdogDisableHelp
        }
    }
}

/// Inline panel under a daemon row: "Port N is occupied by X (PID Y)" + Kill & start / Cancel.
/// Rendered purely from `ProcessManager.portConflicts` — survives the transient popover closing.
struct PortConflictPanel: View {
    let conflict: ProcessManager.PortConflict
    let onKill: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                    .font(.system(size: 11))
                Text(L10n.portOccupied(conflict.port, conflict.occupant.processName, conflict.occupant.pid))
                    .font(.system(size: 11))
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                Button(action: onKill) {
                    HStack(spacing: 4) {
                        if conflict.resolving { ProgressView().controlSize(.mini) }
                        Text(L10n.killAndStart)
                    }
                }
                .disabled(conflict.resolving)
                Button(L10n.cancel, action: onDismiss)
                    .disabled(conflict.resolving)
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.12)))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }
}

/// Status dot: grey/green/red circle; for `running` — a spinning arc.
struct StatusDot: View {
    let status: DeckStatus

    var body: some View {
        Group {
            if status == .running {
                RunningSpinner()
            } else {
                Circle().fill(color).frame(width: 9, height: 9)
            }
        }
        .frame(width: 14, height: 14)
        .accessibilityElement()
        .accessibilityLabel(L10n.deckStatus(status))
        .help(L10n.deckStatus(status))
    }

    private var color: Color {
        switch status {
        case .idle: return Color(white: 0.72)
        case .running: return .yellow
        case .daemon: return .green
        case .failed: return .red
        }
    }
}

/// Pure-SwiftUI spinner (no `NSProgressIndicator`) — to avoid
/// `_NSDetectedLayoutRecursion` when several spinners are in the popover at once.
struct RunningSpinner: View {
    @State private var spinning = false

    var body: some View {
        Circle()
            .trim(from: 0, to: 0.7)
            .stroke(Color.yellow, style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
            .frame(width: 9, height: 9)
            .rotationEffect(.degrees(spinning ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: spinning)
            .onAppear { spinning = true }
    }
}
