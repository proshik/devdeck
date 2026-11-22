import AppKit
import SwiftUI

/// The Cleanup page: where the Mac disk goes first — the volume bar, the home-folder scan, the
/// known categories that can be freed and the largest folders — then one block per installed
/// container engine: what its docker is made of, with a button per category saying what it will
/// free, and for colima the VM-memory explainer with a restart. Every button confirms first and
/// runs through the normal runner, so nothing here has its own process code.
///
/// One grouped Form like the window's other pages (UI-02): a section per subject, each action a
/// row with its button at the trailing edge and what it costs under it.
struct CleanupView: View {
    @Environment(CleanupModel.self) private var model
    @Environment(DiskOverviewModel.self) private var disk
    @Environment(ProcessManager.self) private var manager

    @State private var pending: Pending?
    @State private var review: ReviewSheet?

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

    private struct ReviewSheet: Identifiable {
        let id = UUID()
        let review: DiskOverviewModel.Review
    }

    /// Scroll targets: the VM-disk row of the folders list jumps to its engine's section.
    private static func anchor(_ host: DockerHost) -> String { "section.\(host.rawValue)" }

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section {
                    EmptyView()
                } footer: {
                    FormFooter(L10n.cleanupIntro)
                }
                macDiskSection
                if let result = disk.result {
                    candidatesSection(result)
                    largestSection(result, proxy: proxy)
                }
                ForEach(model.visibleHosts, id: \.self) { host in
                    hostSection(host).id(Self.anchor(host))
                    if host == .colima, model.isRunning(.colima) { memorySection }
                }
                if let id = model.lastRunID {
                    Section(L10n.cleanupLastRun) {
                        LogView(id: id).frame(height: 220)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .navigationTitle(L10n.cleanup)
        .toolbar {
            // No spinner here: in the macOS 26 toolbar it sits in an empty glass capsule, and each
            // box already shows its own progress while the disabled button says the rest.
            ToolbarItem {
                Button(L10n.cleanupRefresh) { Task { await refreshAll() } }
                    .disabled(model.isRefreshing)
            }
            ToolbarItem {
                if disk.isScanning {
                    Button(L10n.diskScanStop) { disk.stopScan() }
                } else {
                    Button(L10n.diskScan) { disk.startScan() }
                        .disabled(!disk.canScan)
                }
            }
        }
        .task { await refreshAll() }
        // A finished action changes the numbers — re-read them (and the disks) without a click.
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
        .sheet(item: $review) { sheet in
            DeletionConfirmation(review: sheet.review) {
                let acted = disk.confirmDeletion(sheet.review)
                // Nothing passed the last check: keep the sheet, now showing why.
                review = disk.isDeleting ? nil : ReviewSheet(review: acted)
            } cancel: {
                review = nil
            }
        }
    }

    private func refreshAll() async {
        await disk.refreshMacDisk()
        await manager.refreshVMDisk()
        await manager.refreshVMSample()
        await model.refresh()
    }

    // MARK: Mac disk

    private var macDiskSection: some View {
        Section {
            if let mac = disk.macDisk {
                DiskBar(label: L10n.macDisk, info: mac)
            }
            if let progress = disk.progress {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(L10n.diskScanning(files: Self.count(progress.files),
                                           size: DockerUsage.formatBytes(progress.bytes),
                                           current: progress.current))
                        .monospacedDigit().foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            if let result = disk.result {
                Text(L10n.diskScanned(date: AppDateFormat.dayMonthTime(result.scannedAt),
                                      files: Self.count(result.fileCount)))
                    .foregroundStyle(.secondary)
                if result.isPartial {
                    DisclosureGroup {
                        ForEach(result.unreadable, id: \.self) { path in
                            Text(Self.tilde(path, root: result.root)).font(.caption).foregroundStyle(.secondary)
                        }
                    } label: {
                        Text(L10n.diskPartial(result.unreadableCount)).foregroundStyle(.secondary)
                    }
                }
                if disk.sizesMayBeStale {
                    Text(L10n.diskAfterRun).font(.caption).foregroundStyle(.secondary)
                }
            } else if !disk.isScanning {
                Text(L10n.diskNeverScanned).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(L10n.macDisk)
        }
    }

    // MARK: can be freed

    private func candidatesSection(_ result: DiskScanResult) -> some View {
        Section {
            if result.candidates.isEmpty {
                Text(L10n.diskCanFreeEmpty).foregroundStyle(.secondary)
            }
            ForEach(result.candidates, id: \.path) { candidate in
                candidateRow(candidate, result: result)
            }
            if result.smallCandidateCount > 0 {
                Text(L10n.diskSmallCandidates(count: result.smallCandidateCount,
                                              size: DockerUsage.formatBytes(result.smallCandidateBytes)))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !result.candidates.isEmpty {
                FormActionRow {
                    if disk.deletionState == .running { ProgressView().controlSize(.small) }
                    Button(L10n.diskFreeSelected(DockerUsage.formatBytes(disk.selectedBytes))) {
                        review = ReviewSheet(review: disk.review())
                    }
                    .disabled(!disk.canDelete)
                }
            }
        } header: {
            Text(L10n.diskCanFree)
        } footer: {
            FormFooter(L10n.diskCanFreeNote)
        }
    }

    private func candidateRow(_ candidate: DiskCandidate, result: DiskScanResult) -> some View {
        let age = Date().timeIntervalSince1970 - candidate.newestModification
        let recent = candidate.newestModification > 0 && age < DiskOverviewModel.recentlyChanged
        return Toggle(isOn: Binding(get: { disk.selection.contains(candidate.path) },
                                    set: { _ in disk.toggle(candidate.path) })) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(L10n.diskCategoryTitle(candidate.category, project: Self.projectName(candidate)))
                    Spacer(minLength: 8)
                    Text(DockerUsage.formatBytes(candidate.bytes)).monospacedDigit()
                }
                Text(detailLine(candidate, result: result, age: age))
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if recent {
                    Text(L10n.diskMaybeBuilding).font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .toggleStyle(.checkbox)
        .disabled(disk.isScanning || model.isBusy)
    }

    private func detailLine(_ candidate: DiskCandidate, result: DiskScanResult, age: TimeInterval) -> String {
        var parts: [String] = []
        if candidate.category.fixedRelativePath == nil || candidate.category == .goModules {
            parts.append(Self.tilde(candidate.path, root: result.root))
        }
        if candidate.newestModification > 0 { parts.append(L10n.diskModified(L10n.age(max(0, age)))) }
        parts.append(L10n.diskCategoryCost(candidate.category))
        return parts.joined(separator: " · ")
    }

    private static func projectName(_ candidate: DiskCandidate) -> String? {
        guard candidate.category.projectManifest != nil else { return nil }
        return ((candidate.path as NSString).deletingLastPathComponent as NSString).lastPathComponent
    }

    // MARK: largest folders

    /// Top-level folders from this size are listed one by one; the rest is one "other" line.
    static let largestFloor: UInt64 = 1_073_741_824

    private func largestSection(_ result: DiskScanResult, proxy: ScrollViewProxy) -> some View {
        let top = result.tree.children.filter { $0.bytes >= Self.largestFloor }
        let shown = top.reduce(UInt64(0)) { $0 + $1.bytes }
        let rest = result.tree.bytes > shown ? result.tree.bytes - shown : 0
        return Section {
            ForEach(top, id: \.name) { node in
                if node.name == ".colima", model.visibleHosts.contains(.colima) {
                    FormNavigationRow(title: "~/.colima (\(L10n.diskVMDiskLabel))",
                                      value: DockerUsage.formatBytes(node.bytes)) {
                        withAnimation { proxy.scrollTo(Self.anchor(.colima), anchor: .top) }
                    }
                } else {
                    FolderRow(node: node, path: result.root + "/" + node.name, root: result.root)
                }
            }
            if rest > 0 {
                LabeledContent(L10n.diskOther) {
                    Text(DockerUsage.formatBytes(rest)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if !result.skipped.isEmpty {
                DisclosureGroup {
                    ForEach(result.skipped, id: \.self) { path in
                        Text(Self.tilde(path, root: result.root)).font(.caption).foregroundStyle(.secondary)
                    }
                } label: {
                    Text(L10n.diskSkippedTitle).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text(L10n.diskLargest)
        } footer: {
            FormFooter(L10n.diskLargestNote + (result.skipped.isEmpty ? "" : " " + L10n.diskSkippedNote))
        }
    }

    // MARK: per-engine sections

    @ViewBuilder
    private func hostSection(_ host: DockerHost) -> some View {
        Section {
            if host == .colima, model.isRunning(.colima), let vm = manager.cachedVMDisk {
                DiskBar(label: L10n.diskVM, info: vm)
                if vm.fraction >= VMDiskInfo.cleanupHintFraction {
                    Text(L10n.cleanupDiskPressureNote)
                        .font(.caption)
                        .foregroundStyle(DiskBar.color(vm.fraction))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let usage = model.usage[host] {
                usageRows(usage, host)
            } else if model.isRefreshing && model.usage.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else {
                Text(host == .minikube || model.isRunning(host) ? L10n.dockerHostUnavailable : L10n.engineNotRunning)
                    .foregroundStyle(.secondary)
            }
            vmDiskFileRows(host)
        } header: {
            Text(L10n.dockerHostTitle(host, minikubeDriver: host == .minikube ? model.facts.minikubeDriver : nil,
                                      minikubeEngine: host == .minikube ? model.minikubeEngine : nil))
        } footer: {
            if model.usage[host] != nil, let note = L10n.dockerHostNote(host, minikubeEngine: model.minikubeEngine) {
                FormFooter(note)
            }
        }
    }

    @ViewBuilder
    private func usageRows(_ usage: DockerUsage, _ host: DockerHost) -> some View {
        ForEach(usageEntries(usage, host)) { entry in
            VStack(alignment: .leading, spacing: 2) {
                usageRow(entry.label, entry.row)
                // The node's disk is one of the engine's volumes; say so, or the two sections
                // read as 45 GB counted twice.
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
        }
        // Without it the rows add up to less than the disk: minikube keeps its PVCs,
        // etcd and logs in the same volume, beside the docker it reports on.
        if let other = unaccounted(usage, host), other >= Self.unaccountedFloor {
            usageLine(L10n.usageUnaccounted, L10n.usageUnaccountedRow(DockerUsage.formatBytes(other), host))
                .id(RowID(host: host, item: "unaccounted"))
        }
        // The opposite gap: rows past the disk are shared layers counted twice.
        if let over = overcounted(usage, host), over >= Self.unaccountedFloor {
            Text(L10n.usageOvercounted(DockerUsage.formatBytes(over)))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .id(RowID(host: host, item: "overcounted"))
        }
        if let tests = usage.testContainers, !tests.isEmpty {
            VStack(alignment: .leading, spacing: 2) { testContainersRows(usage, tests, host) }
                .id(RowID(host: host, item: "tests"))
            testContainersActionRow(host).id(RowID(host: host, item: "tests.action"))
        }
        ForEach(CleanupAction.allCases, id: \.self) { action in
            actionRow(action, host).id(RowID(host: host, item: action.rawValue))
        }
    }

    /// What the VM's disk takes on the Mac — shown whether the engine runs or not.
    @ViewBuilder
    private func vmDiskFileRows(_ host: DockerHost) -> some View {
        switch host {
        case .colima:
            ForEach(model.facts.colimaDisks, id: \.instance) { file in
                LabeledContent(L10n.vmDiskFileLabel + (model.facts.colimaDisks.count > 1 ? " · \(file.instance)" : "")) {
                    Text(file.allocatedBytes.map(DockerUsage.formatBytes) ?? "—")
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                .help(L10n.vmDiskFileNote)
                .id(RowID(host: host, item: "disk.\(file.instance)"))
            }
        case .dockerDesktop:
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.vmDiskFileLabel)
                Text(L10n.dockerRawUnavailable).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .id(RowID(host: host, item: "disk"))
        case .minikube:
            EmptyView()
        }
    }

    /// A row's identity in the Form. The daemons have the same categories and actions, and a Form
    /// keys rows by ID across all its sections: the same ID in two sections shifts the rows — the
    /// colima section's last row turned into its footer and minikube's footer into a row.
    struct RowID: Hashable {
        let host: DockerHost
        let item: String
    }

    /// One line per category, biggest first: the page exists to answer "where did the disk go".
    private struct UsageEntry: Identifiable {
        let host: DockerHost
        let label: String
        let row: DockerUsageRow?
        let isVolumes: Bool
        var id: RowID { RowID(host: host, item: label) }
    }

    private func usageEntries(_ usage: DockerUsage, _ host: DockerHost) -> [UsageEntry] {
        [UsageEntry(host: host, label: L10n.usageVolumes, row: usage.volumes, isVolumes: true),
         UsageEntry(host: host, label: L10n.usageImages, row: usage.images, isVolumes: false),
         UsageEntry(host: host, label: L10n.usageBuildCache, row: usage.buildCache, isVolumes: false),
         UsageEntry(host: host, label: L10n.usageContainers, row: usage.containers, isVolumes: false)]
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

    /// The whole the rows should add up to: the VM disk for colima's daemon, the node's volume
    /// (as its engine's daemon measures it) for minikube. Docker Desktop has no disk probe.
    private func total(_ host: DockerHost) -> UInt64? {
        switch host {
        case .colima: return manager.cachedVMDisk?.usedBytes
        case .dockerDesktop: return nil
        case .minikube: return model.minikubeEngine.flatMap { model.usage[$0]?.nestedDaemonVolumeBytes }
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
    }

    private func actionRow(_ action: CleanupAction, _ host: DockerHost) -> some View {
        actionRow(title: L10n.cleanupActionTitle(action),
                  effect: L10n.cleanupEffect(action, host),
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

    /// What the action frees and — always visible — what it costs afterwards, with its button at
    /// the trailing edge of the row.
    private func actionRow(title: String, effect: String, running: Bool, estimate: UInt64?,
                           enabled: Bool, action: @escaping () -> Void) -> some View {
        FormActionRow {
            VStack(alignment: .leading, spacing: 2) {
                if let estimate {
                    Text(L10n.cleanupFrees(DockerUsage.formatBytes(estimate)))
                        .monospacedDigit()
                        .foregroundStyle(estimate > 0 ? .primary : .secondary)
                }
                Text(effect)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if running { ProgressView().controlSize(.small) }
            Button(title, action: action)
                .disabled(model.isBusy || disk.isScanning || !enabled)
        }
    }

    // MARK: memory section

    private var memorySection: some View {
        Section {
            if let vm = manager.vmMemorySample() {
                LabeledContent(HeaderMetric.vmEngine.title(engineName: "colima")) {
                    Text(vm.format()).monospacedDigit().foregroundStyle(DiskBar.color(vm.fraction))
                }
            }
            FormActionRow {
                if model.restartState == .running { ProgressView().controlSize(.small) }
                Button(L10n.restartEngine("colima")) { pending = .restart }
                    .disabled(model.isBusy || disk.isScanning)
            }
        } header: {
            Text(L10n.cleanupMemorySection)
        } footer: {
            FormFooter(L10n.cleanupMemoryNote)
        }
    }

    // MARK: confirm + run

    private var pendingTitle: String {
        switch pending {
        case .action(let a, let h): return L10n.cleanupConfirmTitle(a, h)
        case .testContainers(let h):
            return L10n.testContainersConfirmTitle(h, count: model.abandonedTestContainers(on: h).count)
        case .restart: return L10n.restartEngineConfirmTitle("colima")
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

    static func count(_ value: Int) -> String {
        value.formatted(.number.locale(AppDateFormat.locale()))
    }

    /// `/Users/u/work/x` → `~/work/x`.
    static func tilde(_ path: String, root: String) -> String {
        path == root ? "~" : (path.hasPrefix(root + "/") ? "~" + path.dropFirst(root.count) : path)
    }
}

/// "Mac disk ████░░ 694 / 926 GB · 79%" — the same bar for the Mac volume and the VM disk.
struct DiskBar: View {
    let label: String
    let info: VMDiskInfo

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.20))
                    Capsule().fill(Self.color(info.fraction))
                        .frame(width: max(2, geo.size.width * info.fraction))
                }
            }
            .frame(height: 6)
            Text(info.format()).monospacedDigit().foregroundStyle(Self.color(info.fraction))
        }
    }

    static func color(_ fraction: Double) -> Color {
        fraction < 0.70 ? .green : (fraction < 0.85 ? .yellow : .red)
    }
}

/// A folder of the scan: its size, a Finder button, and — when the scan kept bigger folders inside
/// it — a disclosure down to them. Measured only; nothing here deletes.
private struct FolderRow: View {
    let node: DiskNode
    let path: String
    let root: String

    var body: some View {
        if node.children.isEmpty {
            label
        } else {
            DisclosureGroup {
                ForEach(node.children, id: \.name) { child in
                    FolderRow(node: child, path: path + "/" + child.name, root: root)
                }
                if node.otherBytes >= DiskScanner.treeFloor {
                    LabeledContent(L10n.diskOther) {
                        Text(DockerUsage.formatBytes(node.otherBytes)).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            } label: {
                label
            }
        }
    }

    private var label: some View {
        FormActionRow {
            VStack(alignment: .leading, spacing: 1) {
                Text(path == root + "/" + node.name ? CleanupView.tilde(path, root: root) : node.name)
                    .lineLimit(1).truncationMode(.middle)
                if let category = node.category {
                    Text(L10n.diskCategoryTitle(category, project: nil)).font(.caption).foregroundStyle(.secondary)
                }
            }
        } actions: {
            Text(DockerUsage.formatBytes(node.bytes)).monospacedDigit().foregroundStyle(.secondary)
            Button(L10n.diskShowInFinder) {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .controlSize(.small)
        }
    }
}

/// The last word before a deletion: every path, its size, the total — and what will be skipped
/// and why. A sheet rather than an alert: an alert cannot hold the full list.
private struct DeletionConfirmation: View {
    let review: DiskOverviewModel.Review
    let confirm: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section {
                    ForEach(review.accepted, id: \.path) { candidate in
                        LabeledContent {
                            Text(DockerUsage.formatBytes(candidate.bytes)).monospacedDigit()
                        } label: {
                            Text(candidate.path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                        }
                    }
                } header: {
                    Text(L10n.diskConfirmTitle)
                } footer: {
                    FormFooter(L10n.diskConfirmNote)
                }
                if !review.rejected.isEmpty {
                    Section(L10n.diskConfirmSkipped) {
                        ForEach(review.rejected, id: \.self) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.candidate.path).lineLimit(1).truncationMode(.middle)
                                Text(L10n.diskRejection(item.reason)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)
            HStack {
                Spacer()
                Button(L10n.cancel, role: .cancel, action: cancel).keyboardShortcut(.cancelAction)
                Button(L10n.diskConfirmDelete(DockerUsage.formatBytes(review.acceptedBytes)),
                       role: .destructive, action: confirm)
                    .disabled(review.accepted.isEmpty)
            }
            .padding()
        }
        .frame(minWidth: 560, minHeight: 320)
    }
}
