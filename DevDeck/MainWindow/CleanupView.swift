import SwiftUI

/// The Cleanup page: `docker system df` for each daemon with one button per reclaimable category,
/// the VM-memory explainer with a colima restart, and the log of the last action. Every button
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
            }
        }
    }

    // MARK: per-daemon box

    private func hostBox(_ host: DockerHost) -> some View {
        GroupBox(L10n.dockerHostTitle(host)) {
            VStack(alignment: .leading, spacing: 6) {
                if let usage = model.usage[host] {
                    usageRow(L10n.usageImages, usage.images)
                    usageRow(L10n.usageContainers, usage.containers)
                    usageRow(L10n.usageVolumes, usage.volumes)
                    usageRow(L10n.usageBuildCache, usage.buildCache)
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

    private func usageRow(_ label: String, _ row: DockerUsageRow?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).frame(width: 96, alignment: .leading)
            if let row {
                Text(L10n.usageRow(DockerUsage.formatBytes(row.sizeBytes), active: row.active, total: row.total,
                                   reclaimable: DockerUsage.formatBytes(row.reclaimableBytes)))
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
                Text("≈ " + DockerUsage.formatBytes(estimate))
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
