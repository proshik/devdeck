import SwiftUI

/// Minimalist menu bar control deck (variant B — "Commands"/"Chains" sections).
/// A thin view: data from `CommandStore`, statuses from `ProcessManager`, actions live there too.
struct PopoverView: View {
    @Environment(CommandStore.self) private var store
    @Environment(ProcessManager.self) private var manager
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    // Section collapse state is remembered across popover opens and app restarts.
    @AppStorage("popover.section.commands.collapsed") private var commandsCollapsed = false
    @AppStorage("popover.section.daemons.collapsed") private var daemonsCollapsed = false
    @AppStorage("popover.section.chains.collapsed") private var chainsCollapsed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            memoryHeader
                .task {
                    // Refresh colima/minikube health while the popover is open; idle when closed.
                    while !Task.isCancelled {
                        await manager.refreshClusterHealth()
                        try? await Task.sleep(for: .seconds(15))
                    }
                }
            Divider()

            if let error = store.error {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .padding(6)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.85))
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if commands.isEmpty && daemons.isEmpty && store.config.chains.isEmpty {
                        Text(L10n.noCommandsYet)
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                            .padding(12)
                    }

                    if !commands.isEmpty {
                        CollapsibleSection(title: L10n.commands, count: commands.count,
                                           runningCount: runningCommandsCount,
                                           collapsed: $commandsCollapsed) {
                            ForEach(commands) { commandRow($0) }
                        }
                    }

                    if !daemons.isEmpty {
                        CollapsibleSection(title: L10n.daemons, count: daemons.count,
                                           runningCount: aliveDaemonsCount,
                                           collapsed: $daemonsCollapsed) {
                            ForEach(daemons) { commandRow($0) }
                        }
                    }

                    if !store.config.chains.isEmpty {
                        CollapsibleSection(title: L10n.chains, count: store.config.chains.count,
                                           runningCount: runningChainsCount,
                                           collapsed: $chainsCollapsed) {
                            ForEach(store.config.chains) { chainRow($0) }
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Divider()
            footer
        }
        .frame(width: 360)
        .frame(maxHeight: 560)
        .focusEffectDisabled()   // don't draw a focus ring on the first button when the popover opens
        .task {
            while !Task.isCancelled {
                await manager.refreshVMSample()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Header: system memory, refreshed once a second while the popover is open.
    private var memoryHeader: some View {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
            let memory = SystemMemory.current()
            VStack(alignment: .leading, spacing: 5) {
                HStack {
                    Text(L10n.memory).foregroundStyle(.secondary)
                    Spacer()
                    Text(SystemMemory.format(usedBytes: memory.usedBytes, totalBytes: memory.totalBytes))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                }
                .font(.system(size: 11))

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.secondary.opacity(0.20))
                        Capsule().fill(pressureColor(memory.fraction))
                            .frame(width: max(2, geo.size.width * memory.fraction))
                    }
                }
                .frame(height: 4)

                if let health = manager.cachedClusterHealth {
                    HStack {
                        Text(L10n.cluster).foregroundStyle(.secondary)
                        Spacer()
                        Text(L10n.clusterHealthValue(health.level))
                            .foregroundStyle(clusterColor(health.level))
                    }
                    .font(.system(size: 10))
                }

                if memory.swapUsedBytes > 0 {
                    HStack {
                        Text(L10n.swap).foregroundStyle(.secondary)
                        Spacer()
                        Text(SystemMemory.formatGiB(memory.swapUsedBytes))
                            .monospacedDigit()
                            .foregroundStyle(.orange)   // non-zero swap = memory pressure
                    }
                    .font(.system(size: 10))
                }

                if let vm = manager.vmMemorySample() {
                    HStack {
                        Text("VM colima").foregroundStyle(.secondary)
                        Spacer()
                        Text(vm.format())
                            .monospacedDigit()
                            .foregroundStyle(pressureColor(vm.fraction))
                    }
                    .font(.system(size: 10))
                }

                // minikube memory from inside the VM — present only during a run (sampler cache).
                if let mk = manager.minikubeSample() {
                    HStack {
                        Text("VM minikube").foregroundStyle(.secondary)
                        Spacer()
                        Text(mk.format() + (mk.rustcCount > 0 ? " · rustc \(mk.rustcCount)" : ""))
                            .monospacedDigit()
                            .foregroundStyle(pressureColor(mk.fraction))
                    }
                    .font(.system(size: 10))
                }

                if let host = manager.cachedHostSample {
                    if host.pressure != .normal {
                        HStack {
                            Text(L10n.pressure).foregroundStyle(.secondary)
                            Spacer()
                            Text(L10n.pressureValue(host.pressure))
                                .foregroundStyle(host.pressure == .critical ? .red : .orange)
                        }
                        .font(.system(size: 10))
                    }
                    let comp = Int((host.compressorFraction(pageSize: hostPageSize) * 100).rounded())
                    if comp > 0 {
                        HStack {
                            Text(L10n.compressor).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(comp)%").monospacedDigit().foregroundStyle(.secondary)
                        }
                        .font(.system(size: 10))
                    }
                    // Live swap rate (↑ out to disk, ↓ in from disk): distinguishes
                    // "full but stable" from "actively thrashing". Gate at ~0.1 MB/s so
                    // sub-rounding noise doesn't show as "0.0 MB/s".
                    let outRate = manager.cachedSwapOutRatePages ?? 0
                    let inRate = manager.cachedSwapInRatePages ?? 0
                    let gate = 100_000.0
                    let outActive = outRate * Double(hostPageSize) >= gate
                    let inActive = inRate * Double(hostPageSize) >= gate
                    let swapRateText = [
                        outActive ? "↑" + HostMetricsSample.formatRate(pagesPerSec: outRate, pageSize: hostPageSize) : nil,
                        inActive ? "↓" + HostMetricsSample.formatRate(pagesPerSec: inRate, pageSize: hostPageSize) : nil,
                    ].compactMap { $0 }.joined(separator: " ")
                    if !swapRateText.isEmpty {
                        HStack {
                            Text(L10n.swapRate).foregroundStyle(.secondary)
                            Spacer()
                            Text(swapRateText)
                                .monospacedDigit()
                                .foregroundStyle(.orange)
                        }
                        .font(.system(size: 10))
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
        }
    }

    private func pressureColor(_ fraction: Double) -> Color {
        fraction < 0.70 ? .green : (fraction < 0.85 ? .yellow : .red)
    }

    private func clusterColor(_ level: ClusterHealthLevel) -> Color {
        switch level {
        case .healthy: return .green
        case .degraded: return .orange
        case .down: return .red
        case .unknown: return .gray
        }
    }

    // MARK: splitting and counters

    /// Regular commands (not daemons).
    private var commands: [Command] { store.config.commands.filter { !$0.isDaemon } }
    /// Daemon commands (long-running).
    private var daemons: [Command] { store.config.commands.filter { $0.isDaemon } }

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
        DeckRow(
            name: command.name,
            needsSudo: command.needsSudo,
            indicator: StatusIndicator.forCommand(manager.states[command.id]),
            onToggle: { toggleCommand(command) },
            onLogs: { openItem(.command(command.id)) }
        )
    }

    private func chainRow(_ chain: Chain) -> some View {
        DeckRow(
            name: chain.name,
            needsSudo: false,
            indicator: StatusIndicator.forChain(manager.chainStates[chain.id]),
            onToggle: { toggleChain(chain) },
            onLogs: { openItem(.chain(chain.id)) }
        )
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Button(L10n.openDevDeck) { openMainWindow() }
                .buttonStyle(.plain)
            Spacer(minLength: 10)
            Button { revealLog() } label: {
                Image(systemName: "doc.text")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.revealLogHelp)
            Button(L10n.quit) { confirmQuit() }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func revealLog() {
        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.shared.fileURL])
    }

    private func confirmQuit() {
        // If there are daemons, let applicationShouldTerminate show the "Kill / Keep / Cancel"
        // dialog (which is itself the confirmation). Otherwise — a simple quit confirmation.
        guard !manager.hasLiveDaemons() else {
            NSApp.terminate(nil)
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L10n.quitConfirmTitle
        alert.informativeText = L10n.quitConfirmMessage
        alert.addButton(withTitle: L10n.quitButton)
        alert.addButton(withTitle: L10n.cancel)
        if alert.runModal() == .alertFirstButtonReturn {
            NSApp.terminate(nil)
        }
    }

    // MARK: actions

    private func toggleCommand(_ command: Command) {
        if StatusIndicator.forCommand(manager.states[command.id]).isStop {
            manager.stop(command.id)
        } else {
            manager.run(command)
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
        appModel.selection = selection
        openMainWindow()
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate()   // macOS 14+: without the deprecated ignoringOtherApps
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
                    Text(title.uppercased())
                        .font(.system(size: 10, weight: .bold))
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
                .padding(.horizontal, 12)
                .padding(.top, 8)
                .padding(.bottom, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !collapsed {
                content()
            }
        }
    }
}

/// One deck row: status dot · name (· sudo lock) · ▶/■ · ☰ logs.
struct DeckRow: View {
    let name: String
    let needsSudo: Bool
    let indicator: DeckIndicator
    let onToggle: () -> Void
    let onLogs: () -> Void

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

            Button(action: onToggle) {
                Image(systemName: indicator.isStop ? "stop.fill" : "play.fill")
                    .font(.system(size: 15))
                    .frame(width: 30, height: 30)        // large tap target
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(indicator.isStop ? Color.red : Color.green)
            .help(indicator.isStop ? L10n.stop : L10n.run)

            Button(action: onLogs) {
                Image(systemName: "list.bullet.rectangle")
                    .font(.system(size: 14))
                    .frame(width: 30, height: 30)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(L10n.logs)
        }
        .font(.system(size: 13))
        .padding(.leading, 12)
        .padding(.trailing, 16)   // right gap: the scrollbar "slider" won't overlap the buttons
        .padding(.vertical, 2)
        .contentShape(Rectangle())
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
