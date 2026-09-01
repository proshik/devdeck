import SwiftUI

/// The Cleanup page: what the colima disk is actually made of — the fill bar first, then each
/// daemon's own footprint biggest-first, with one button per category saying what it will free —
/// plus the VM-memory explainer with a colima restart and the log of the last action. Every button
/// confirms first and runs through the normal runner, so nothing here has its own process code.
struct CleanupView: View {
    @Environment(CleanupModel.self) private var model
    @Environment(ProcessManager.self) private var manager

    @State private var pending: Pending?

    private enum Pending: Identifiable {
        case action(CleanupAction, DockerHost)
        case restart

        var id: String {
            switch self {
            case .action(let a, let h): return "\(h.rawValue).\(a.rawValue)"
            case .restart: return "restart"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                ForEach(DockerHost.allCases, id: \.self) { hostBox($0) }
                memoryBox
                if let id = model.lastRunID {
                    GroupBox(L10n.cleanupLastRun) {
                        LogView(id: id).frame(height: 220)
                    }
                }
            }
            .padding()
        }
        .task {
            await manager.refreshVMDisk()
            await manager.refreshVMSample()
            await model.refresh()
        }
        // A finished action changes the numbers — re-read them (and the disk) without a click.
        .onChange(of: lastRunState) { _, new in
            guard new == .succeeded || isFailed(new) else { return }
            Task {
                await manager.refreshVMDisk()
                await model.refresh()
            }
        }
        .alert(pendingTitle, isPresented: Binding(
            get: { pending != nil },
            set: { if !$0 { pending = nil } }
        ), presenting: pending) { p in
            Button(confirmButton(p), role: .destructive) { execute(p) }
            Button(L10n.cancel, role: .cancel) {}
        } message: { p in
            Text(confirmMessage(p))
        }
    }

    // MARK: header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.cleanup).font(.title2).bold()
                Spacer()
                if model.isRefreshing { ProgressView().controlSize(.small) }
                Button(L10n.cleanupRefresh) {
                    Task {
                        await manager.refreshVMDisk()
                        await manager.refreshVMSample()
                        await model.refresh()
                    }
                }
                .disabled(model.isRefreshing)
            }
            Text(L10n.cleanupIntro).font(.caption).foregroundStyle(.secondary)
            if let disk = manager.cachedVMDisk {
                HStack(spacing: 8) {
                    Text(L10n.diskVM).foregroundStyle(.secondary)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.20))
                            Capsule().fill(pressureColor(disk.fraction))
                                .frame(width: max(2, geo.size.width * disk.fraction))
                        }
                    }
                    .frame(height: 6)
                    Text(disk.format()).monospacedDigit().foregroundStyle(pressureColor(disk.fraction))
                }
                .font(.callout)
                if disk.fraction >= VMDiskInfo.cleanupHintFraction {
                    Text(L10n.cleanupDiskPressureNote)
                        .font(.caption)
                        .foregroundStyle(pressureColor(disk.fraction))
                }
            }
        }
    }

    // MARK: per-daemon box

    private func hostBox(_ host: DockerHost) -> some View {
        GroupBox(L10n.dockerHostTitle(host)) {
            VStack(alignment: .leading, spacing: 6) {
                if let usage = model.usage[host] {
                    if let note = L10n.dockerHostNote(host) {
                        Text(note).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(usageEntries(usage)) { entry in
                        usageRow(entry.label, entry.row)
                        // The node's disk is one of colima's volumes; say so, or the two boxes read
                        // as 45 GB counted twice.
                        if entry.isVolumes {
                            if let nested = usage.nestedDaemonVolumeBytes, nested > 0 {
                                volumeDetailLine(L10n.usageNestedVolume(DockerUsage.formatBytes(nested)))
                            }
                            // The two lines add up to most of the row above — which is the whole
                            // point: the volumes are where the disk went, and this says where to.
                            if let abandoned = usage.pruneableVolumeBytes, abandoned > 0 {
                                volumeDetailLine(L10n.usageAbandonedVolumes(DockerUsage.formatBytes(abandoned)))
                            }
                        }
                    }
                    Divider().padding(.vertical, 2)
                    ForEach(CleanupAction.allCases, id: \.self) { action in
                        actionRow(action, host)
                    }
                } else if model.isRefreshing && model.usage.isEmpty {
                    ProgressView().controlSize(.small)
                } else {
                    Text(L10n.dockerHostUnavailable).foregroundStyle(.secondary).font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    /// One line per category, biggest first: the page exists to answer "where did the disk go".
    private struct UsageEntry: Identifiable {
        let label: String
        let row: DockerUsageRow?
        let isVolumes: Bool
        var id: String { label }
    }

    private func usageEntries(_ usage: DockerUsage) -> [UsageEntry] {
        [UsageEntry(label: L10n.usageVolumes, row: usage.volumes, isVolumes: true),
         UsageEntry(label: L10n.usageImages, row: usage.images, isVolumes: false),
         UsageEntry(label: L10n.usageBuildCache, row: usage.buildCache, isVolumes: false),
         UsageEntry(label: L10n.usageContainers, row: usage.containers, isVolumes: false)]
            .sorted { ($0.row?.sizeBytes ?? 0) > ($1.row?.sizeBytes ?? 0) }
    }

    private func volumeDetailLine(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.leading, 104)
    }

    private func usageRow(_ label: String, _ row: DockerUsageRow?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).frame(width: 96, alignment: .leading)
            if let row {
                Text(L10n.usageRow(DockerUsage.formatBytes(row.sizeBytes), active: row.active, total: row.total))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            } else {
                Text("—").foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }

    private func actionRow(_ action: CleanupAction, _ host: DockerHost) -> some View {
        HStack(spacing: 8) {
            Button(L10n.cleanupActionTitle(action)) { pending = .action(action, host) }
                .disabled(model.isBusy)
            if model.state(action, on: host) == .running {
                ProgressView().controlSize(.small)
            }
            Spacer()
            if let estimate = model.estimate(action, on: host) {
                Text(L10n.cleanupFrees(DockerUsage.formatBytes(estimate)))
                    .monospacedDigit()
                    .foregroundStyle(estimate > 0 ? .primary : .secondary)
            }
        }
        .font(.callout)
    }

    // MARK: memory box

    private var memoryBox: some View {
        GroupBox(L10n.cleanupMemorySection) {
            VStack(alignment: .leading, spacing: 6) {
                if let vm = manager.vmMemorySample() {
                    HStack(spacing: 8) {
                        Text("VM colima").foregroundStyle(.secondary)
                        Text(vm.format()).monospacedDigit().foregroundStyle(pressureColor(vm.fraction))
                    }
                    .font(.callout)
                }
                Text(L10n.cleanupMemoryNote).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(L10n.restartColima) { pending = .restart }
                        .disabled(model.isBusy)
                    if model.restartState == .running { ProgressView().controlSize(.small) }
                }
                .font(.callout)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        }
    }

    // MARK: confirm + run

    private var pendingTitle: String {
        switch pending {
        case .action(let a, let h): return L10n.cleanupConfirmTitle(a, h)
        case .restart: return L10n.restartColimaConfirmTitle
        case nil: return ""
        }
    }

    private func confirmMessage(_ p: Pending) -> String {
        switch p {
        case .action(let a, _): return L10n.cleanupConfirmMessage(a)
        case .restart: return L10n.restartColimaConfirmMessage
        }
    }

    private func confirmButton(_ p: Pending) -> String {
        switch p {
        case .action: return L10n.cleanupConfirmButton
        case .restart: return L10n.restartColimaConfirmButton
        }
    }

    private func execute(_ p: Pending) {
        switch p {
        case .action(let a, let h): model.run(a, on: h)
        case .restart: model.restartColima()
        }
    }

    private var lastRunState: ProcessManager.RunState? {
        model.lastRunID.flatMap { manager.states[$0] }
    }

    private func isFailed(_ state: ProcessManager.RunState?) -> Bool {
        if case .failed = state { return true }
        return false
    }

    private func pressureColor(_ fraction: Double) -> Color {
        fraction < 0.70 ? .green : (fraction < 0.85 ? .yellow : .red)
    }
}
