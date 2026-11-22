import Foundation
import Observation

/// The Mac-disk part of the Cleanup page: the volume bar, the home-folder scan (on request,
/// cancellable, remembered), the selection of known categories and their deletion.
///
/// The deletion is a synthetic command started through `CleanupModel`, so it shares the page's
/// "last action" log and busy lock with the docker cleanups — and a scan never overlaps a run.
@MainActor
@Observable
final class DiskOverviewModel {
    /// The volume holding the home folder; nil until read (or when it cannot be).
    private(set) var macDisk: VMDiskInfo?
    /// The last finished scan, from disk until a new one finishes.
    private(set) var result: DiskScanResult?
    /// Non-nil while a scan runs — what it has walked so far.
    private(set) var progress: DiskScanProgress?
    /// Candidate paths the user ticked. Nothing is ticked until they tick it.
    private(set) var selection: Set<String> = []
    /// Set once a deletion has finished: the remaining sizes are the scan's, not today's.
    private(set) var sizesMayBeStale = false

    var isScanning: Bool { progress != nil }

    /// A candidate changed more recently than this is flagged "a build may be running".
    static let recentlyChanged: TimeInterval = 3600

    /// Build output changed within the last hour. Caches are left out: whatever runs on the Mac
    /// writes into them all the time, so on them the flag would always be up and mean nothing.
    static func mayBeBuilding(_ candidate: DiskCandidate, now: Date) -> Bool {
        guard candidate.category.isBuildOutput, candidate.newestModification > 0 else { return false }
        return now.timeIntervalSince1970 - candidate.newestModification < recentlyChanged
    }

    /// The folder scanned and the one every deletion must stay inside, resolved through `realpath`.
    @ObservationIgnored let root: String
    @ObservationIgnored private let cleanup: CleanupModel
    @ObservationIgnored private let reader: any DirectoryReading
    @ObservationIgnored private let inspector: any DeletionInspecting
    @ObservationIgnored private let volume: any VolumeUsageProbing
    @ObservationIgnored private let store: any DiskScanStoring
    @ObservationIgnored private var scanTask: Task<Void, Never>?
    /// What the deletion now running was asked to remove — forgotten once it finishes.
    @ObservationIgnored private var removing: [DiskCandidate] = []
    /// Waits for that run to end, whether or not the page is still open.
    @ObservationIgnored private var deletionWatch: Task<Void, Never>?
    /// How often the watch looks at the run's state.
    @ObservationIgnored var deletionPollInterval: Duration = .milliseconds(250)
    /// How often the page sees the scan's progress.
    @ObservationIgnored var progressInterval: Duration = .milliseconds(250)

    init(cleanup: CleanupModel,
         root: String = NSHomeDirectory(),
         reader: any DirectoryReading = LiveDirectoryReader(),
         inspector: any DeletionInspecting = LiveDeletionInspector(),
         volume: any VolumeUsageProbing = LiveVolumeUsageProbe(),
         store: any DiskScanStoring = DiskScanStore()) {
        self.cleanup = cleanup
        self.root = inspector.realPath(root) ?? root
        self.reader = reader
        self.inspector = inspector
        self.volume = volume
        self.store = store
        // A result of another root (a development scan root, a renamed home) is not this one's.
        result = store.load().flatMap { $0.root == self.root ? $0 : nil }
    }

    // MARK: disk bar

    func refreshMacDisk() async {
        let volume = self.volume, root = self.root
        macDisk = await Task.detached(priority: .utility) { volume.sample(root) }.value
    }

    // MARK: scan

    /// A finished deletion not yet taken out of the result. Until it is, neither a scan (it would
    /// be overwritten by stale bookkeeping) nor another deletion (it would replace the batch
    /// being reconciled) may start.
    private var isReconciling: Bool { !removing.isEmpty }

    /// Scanning reads the disk the cleanups are writing: neither starts while the other runs.
    var canScan: Bool { !isScanning && !cleanup.isBusy && !isReconciling }

    func startScan() {
        guard canScan else { return }
        let reader = self.reader, root = self.root
        let box = ProgressBox()
        progress = DiskScanProgress()
        scanTask = Task { [weak self] in
            let work = Task.detached(priority: .utility) { () -> DiskScanResult? in
                try? DiskScanner(reader: reader, root: root)
                    .scan(isCancelled: { Task.isCancelled }, progress: { box.value = $0 })
            }
            let poller = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    guard let self, self.progress != nil else { return }
                    self.progress = box.value
                    try? await Task.sleep(for: self.progressInterval)
                }
            }
            let scanned = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            poller.cancel()
            self?.finishScan(Task.isCancelled ? nil : scanned)
        }
    }

    func stopScan() {
        scanTask?.cancel()
    }

    /// For tests: the running scan, finished.
    func waitForScan() async {
        await scanTask?.value
    }

    private func finishScan(_ scanned: DiskScanResult?) {
        progress = nil
        scanTask = nil
        // Cancelled or failed: the previous result stays, nothing half-done is saved.
        guard let scanned else { return }
        result = scanned
        sizesMayBeStale = false
        // A path that is no longer offered cannot stay ticked.
        selection.formIntersection(scanned.candidates.map(\.path))
        store.save(scanned)
    }

    // MARK: selection

    func toggle(_ path: String) {
        guard result?.candidates.contains(where: { $0.path == path }) == true else { return }
        if !selection.insert(path).inserted { selection.remove(path) }
    }

    var selectedCandidates: [DiskCandidate] {
        (result?.candidates ?? []).filter { selection.contains($0.path) }
    }

    var selectedBytes: UInt64 { selectedCandidates.reduce(0) { $0 + $1.bytes } }

    /// Deleting is offered when something is ticked and nothing else is running or scanning.
    var canDelete: Bool { !selection.isEmpty && !isScanning && !cleanup.isBusy && !isReconciling }

    // MARK: deletion

    struct Review: Equatable {
        var accepted: [DiskCandidate]
        var rejected: [Rejected]

        struct Rejected: Equatable, Hashable {
            let candidate: DiskCandidate
            let reason: DeletionRejection
        }

        var acceptedBytes: UInt64 { accepted.reduce(0) { $0 + $1.bytes } }
    }

    /// Check every ticked path as it is now — shown in the confirmation before anything runs.
    func review() -> Review {
        let guardian = DeletionGuard(inspector: inspector, root: root)
        var review = Review(accepted: [], rejected: [])
        for candidate in selectedCandidates {
            if let reason = guardian.check(candidate) {
                review.rejected.append(.init(candidate: candidate, reason: reason))
            } else {
                review.accepted.append(candidate)
            }
        }
        return review
    }

    /// "Delete" in the confirmation. Only what the confirmation listed as going is considered —
    /// a path it showed as skipped is never added because it has passed since — and each is
    /// checked once more (time has passed since it opened). Returns what it acted on.
    @discardableResult
    func confirmDeletion(_ shown: Review) -> Review {
        let guardian = DeletionGuard(inspector: inspector, root: root)
        var review = Review(accepted: [], rejected: shown.rejected)
        for candidate in shown.accepted where selection.contains(candidate.path) {
            if let reason = guardian.check(candidate) {
                review.rejected.append(.init(candidate: candidate, reason: reason))
            } else {
                review.accepted.append(candidate)
            }
        }
        // The volume the guard just checked against: every step must still find its path on it.
        guard canDelete, !review.accepted.isEmpty, let device = inspector.entry(at: root)?.device else { return review }
        removing = review.accepted
        let skipped = review.rejected.map { ($0.candidate.path, L10n.diskRejection($0.reason)) }
        cleanup.start(CleanupCommands.removeMacFiles(review.accepted, device: device, skipped: skipped))
        watchDeletion()
        return review
    }

    /// Whether the last `confirmDeletion` started a run — the sheet stays open with the new
    /// reasons when it did not.
    var isDeleting: Bool { isReconciling }

    var deletionState: ProcessManager.RunState? { cleanup.state(of: CleanupCommands.macFilesID) }

    /// The run's state is `.running` from the moment it starts; anything else afterwards —
    /// succeeded, failed, or idle after a stop from its log — is its end. Owned by the model, so
    /// leaving the page does not lose it.
    private func watchDeletion() {
        deletionWatch?.cancel()
        deletionWatch = Task { [weak self] in
            while let self, !Task.isCancelled, self.deletionState == .running {
                try? await Task.sleep(for: self.deletionPollInterval)
            }
            guard let self, !Task.isCancelled else { return }
            await self.deletionFinished(succeeded: self.deletionState == .succeeded)
        }
    }

    /// For tests: the deletion's end, reconciled.
    func waitForDeletion() async {
        await deletionWatch?.value
    }

    /// The deletion command ended (any way): drop what is gone from the result, keep what is not.
    /// A removed directory is checked on disk. A category emptied in place (`~/Library/Caches`)
    /// is gone when the whole run succeeded, or — after a partial failure — when it is empty now;
    /// apps start refilling it at once, so "exists" says nothing about it.
    private func deletionFinished(succeeded: Bool) async {
        guard !removing.isEmpty else { return }
        let finished = removing
        removing = []
        let inspector = self.inspector
        let byPath = Dictionary(finished.map { ($0.path, $0.category) }, uniquingKeysWith: { a, _ in a })
        if var updated = result {
            updated.forgetRemoved(finished.map(\.path)) { path in
                guard let category = byPath[path] else { return true }
                switch category.removal {
                case .directory: return inspector.entry(at: path) != nil
                case .contents, .goModCache:
                    if succeeded { return false }
                    guard inspector.entry(at: path) != nil else { return false }
                    return (try? inspector.entries(of: path).isEmpty) != true
                }
            }
            result = updated
            store.save(updated)
        }
        selection.subtract(finished.map(\.path))
        sizesMayBeStale = true
        await refreshMacDisk()
    }
}

/// The scan writes, the page reads — a few times a second, so a lock is plenty.
private final class ProgressBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = DiskScanProgress()
    var value: DiskScanProgress {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
}
