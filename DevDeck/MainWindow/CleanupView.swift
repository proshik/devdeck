import SwiftUI

/// The Cleanup page: what the colima disk is actually made of — the fill bar first, then each
/// daemon's own footprint biggest-first, with one button per category saying what it will free —
/// plus the VM-memory explainer with a colima restart and the log of the last action. Every button
/// confirms first and runs through the normal runner, so nothing here has its own process code.
struct CleanupView: View {
    @Environment(CleanupModel.self) private var model
    @Environment(ProcessManager.self) private var manager
    @Environment(EngineModel.self) private var engine

    @State private var pending: Pending?

    private enum Pending: Identifiable {
        case action(CleanupAction, DockerHost)
        case testContainers(DockerHost)
        case restart

        var id: String {
            switch self {
            case .action(let a, let h): return "\(h.rawValue).\(a.rawValue)"
            case .testContainers(let h): return "\(h.rawValue).testContainers"
            case .restart: return "restart"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                ForEach(model.visibleHosts, id: \.self) { hostBox($0) }
                if engine.activeKind == .colima { memoryBox }
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
            Text(L10n.cleanupIntro(engineName: engine.activeName)).font(.caption).foregroundStyle(.secondary)
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
        GroupBox(L10n.dockerHostTitle(host, engineName: engine.activeName)) {
            VStack(alignment: .leading, spacing: 6) {
                if let usage = model.usage[host] {
                    if let note = L10n.dockerHostNote(host, engineName: engine.activeName) {
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
                    // Without it the rows add up to less than the box: minikube keeps its PVCs,
                    // etcd and logs in the same volume, beside the docker it reports on.
                    if let other = unaccounted(usage, host), other >= Self.unaccountedFloor {
                        usageLine(L10n.usageUnaccounted,
                                  L10n.usageUnaccountedRow(DockerUsage.formatBytes(other), host))
                    }
                    // The opposite gap: rows past the disk are shared layers counted twice.
                    if let over = overcounted(usage, host), over >= Self.unaccountedFloor {
                        Text(L10n.usageOvercounted(DockerUsage.formatBytes(over)))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let tests = usage.testContainers, !tests.isEmpty {
                        testContainersRows(usage, tests, host)
                    }
                    Divider().padding(.vertical, 2)
                    if let tests = usage.testContainers, !tests.isEmpty {
                        testContainersActionRow(host)
                    }
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

    /// Below this "Other" is rounding and docker's own bookkeeping — not worth a row.
    private static let unaccountedFloor: UInt64 = 256 * 1_048_576

    private func unaccounted(_ usage: DockerUsage, _ host: DockerHost) -> UInt64? {
        total(host).flatMap { usage.unaccountedBytes(of: $0) }
    }

    private func overcounted(_ usage: DockerUsage, _ host: DockerHost) -> UInt64? {
        total(host).flatMap { usage.overcountedBytes(of: $0) }
    }

    /// The whole the rows should add up to: the VM disk for the engine's daemon, the node's volume
    /// (as the engine's daemon measures it) for minikube.
    private func total(_ host: DockerHost) -> UInt64? {
        switch host {
        case .engineVM: return manager.cachedVMDisk?.usedBytes
        case .minikube: return model.usage[.engineVM]?.nestedDaemonVolumeBytes
        }
    }

    /// The running test containers: how many, how many look abandoned, what their volumes hold —
    /// then one line per image with the age range, so a leak reads as "postgres ×44 — 10 h to 3 d".
    @ViewBuilder
    private func testContainersRows(_ usage: DockerUsage, _ tests: [TestContainer], _ host: DockerHost) -> some View {
        let now = model.now()
        usageLine(L10n.usageTestContainers,
                  L10n.usageTestContainersRow(running: tests.count,
                                              abandoned: usage.abandonedTestContainers(now: now).count,
                                              size: DockerUsage.formatBytes(usage.heldBytes(tests))))
        let groups = Dictionary(grouping: tests, by: \.image)
            .sorted { $0.value.count > $1.value.count }
        ForEach(groups, id: \.key) { image, list in
            let ages = list.map { now.timeIntervalSince($0.startedAt) }
            volumeDetailLine(L10n.testContainersGroup(image: image, count: list.count,
                                                      youngest: L10n.age(ages.min() ?? 0),
                                                      oldest: L10n.age(ages.max() ?? 0)))
        }
    }

    private func usageLine(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).frame(width: 96, alignment: .leading)
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.callout)
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
        actionRow(title: L10n.cleanupActionTitle(action),
                  effect: L10n.cleanupEffect(action, host, engineName: engine.activeName),
                  running: model.state(action, on: host) == .running,
                  estimate: model.estimate(action, on: host),
                  enabled: true) { pending = .action(action, host) }
    }

    private func testContainersActionRow(_ host: DockerHost) -> some View {
        actionRow(title: L10n.testContainersAction,
                  effect: L10n.testContainersEffect,
                  running: model.testContainersState(on: host) == .running,
                  estimate: model.abandonedTestContainerBytes(on: host),
                  enabled: !model.abandonedTestContainers(on: host).isEmpty) { pending = .testContainers(host) }
    }

    /// The button, what it will free, and — under it, always visible — what it costs afterwards.
    private func actionRow(title: String, effect: String, running: Bool, estimate: UInt64?,
                           enabled: Bool, action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Button(title, action: action)
                    .disabled(model.isBusy || !enabled)
                if running { ProgressView().controlSize(.small) }
                Spacer()
                if let estimate {
                    Text(L10n.cleanupFrees(DockerUsage.formatBytes(estimate)))
                        .monospacedDigit()
                        .foregroundStyle(estimate > 0 ? .primary : .secondary)
                }
            }
            .font(.callout)
            Text(effect)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.bottom, 4)
    }

    // MARK: memory box

    private var memoryBox: some View {
        GroupBox(L10n.cleanupMemorySection) {
            VStack(alignment: .leading, spacing: 6) {
                if let vm = manager.vmMemorySample() {
                    HStack(spacing: 8) {
                        Text(HeaderMetric.vmEngine.title(engineName: engine.activeName)).foregroundStyle(.secondary)
                        Text(vm.format()).monospacedDigit().foregroundStyle(pressureColor(vm.fraction))
                    }
                    .font(.callout)
                }
                Text(L10n.cleanupMemoryNote).font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button(L10n.restartEngine(engine.activeName ?? "colima")) { pending = .restart }
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
        case .action(let a, let h): return L10n.cleanupConfirmTitle(a, h, engineName: engine.activeName)
        case .testContainers(let h):
            return L10n.testContainersConfirmTitle(h, engineName: engine.activeName,
                                                   count: model.abandonedTestContainers(on: h).count)
        case .restart: return L10n.restartEngineConfirmTitle(engine.activeName ?? "colima")
        case nil: return ""
        }
    }

    private func confirmMessage(_ p: Pending) -> String {
        switch p {
        case .action(let a, _): return L10n.cleanupConfirmMessage(a)
        case .testContainers: return L10n.testContainersConfirmMessage
        case .restart: return L10n.restartEngineConfirmMessage
        }
    }

    private func confirmButton(_ p: Pending) -> String {
        switch p {
        case .action, .testContainers: return L10n.cleanupConfirmButton
        case .restart: return L10n.restartEngineConfirmButton
        }
    }

    private func execute(_ p: Pending) {
        switch p {
        case .action(let a, let h): model.run(a, on: h)
        case .testContainers(let h): model.removeAbandonedTestContainers(on: h)
        case .restart: model.restartEngine()
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
