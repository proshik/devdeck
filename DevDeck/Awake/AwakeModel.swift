import Foundation
import Observation

@MainActor @Observable
final class AwakeModel {
    let manager: ProcessManager
    /// Longest timed session; 0 means indefinitely. The helper enforces the same bound.
    nonisolated static let maxSeconds = 7200
    /// The UI's duration picker. `start(seconds:)` overrides it for one session without moving it.
    var durationSeconds = 7200
    /// Duration of the session last started (0 = indefinitely); nil before the first one.
    private(set) var sessionSeconds: Int?
    private(set) var stopping = false
    private(set) var recovering = false
    private(set) var recoveryAvailable = false
    private(set) var thermalStop = false
    private var restorationFailed = false
    @ObservationIgnored private let hasJournal: () -> Bool
    @ObservationIgnored private let thermalState: () -> ProcessInfo.ThermalState
    /// When the helper's receipt was written — the moment sleep was actually disabled and its
    /// deadline began. Injected so tests read no root-owned file.
    @ObservationIgnored private let readySince: () -> Date?
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(manager: ProcessManager,
         hasJournal: @escaping () -> Bool = { FileManager.default.fileExists(atPath: AwakeHelper.journalURL.path) },
         thermalState: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState },
         readySince: @escaping () -> Date? = {
             (try? FileManager.default.attributesOfItem(atPath: AwakeHelper.readyURL.path))?[.modificationDate] as? Date
         }) {
        self.manager = manager
        self.hasJournal = hasJournal
        self.thermalState = thermalState
        self.readySince = readySince
    }

    deinit { loop?.cancel() }

    var state: ProcessManager.RunState { manager.states[AwakeHelper.daemonID] ?? .idle }
    var isBusy: Bool { state == .running || state == .daemonRunning }
    var isActive: Bool { state == .daemonRunning }
    var error: String? {
        let details = manager.logs[AwakeHelper.daemonID]?.elements.suffix(8).map(\.text).joined(separator: "\n")
        if restorationFailed {
            return [L10n.awakeRestoreFailed, details].compactMap { $0 }.joined(separator: "\n")
        }
        guard case .failed = state else { return nil }
        return details
    }

    /// Seconds left of an active timed session; nil when inactive, indefinite or not yet known.
    func remainingSeconds(now: Date = Date()) -> Int? {
        guard isActive, !recovering, let total = sessionSeconds, total > 0, let since = readySince() else { return nil }
        return max(0, total - Int(now.timeIntervalSince(since).rounded(.down)))
    }

    func startMonitoring() {
        guard loop == nil else { return }
        refresh()
        loop = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func refresh() {
        recoveryAvailable = !isBusy && hasJournal()
        if stopping && recoveryAvailable {
            restorationFailed = true
            thermalStop = false
        }
        if !isBusy && !recoveryAvailable { restorationFailed = false }
        if !isBusy { stopping = false; recovering = false }
        if isBusy && !recovering && !stopping && [.serious, .critical].contains(thermalState()) {
            thermalStop = true
            stop()
        }
    }

    /// `seconds` is this session's duration (0 = indefinitely); nil takes the UI's `durationSeconds`.
    func start(recovery: Bool = false, seconds: Int? = nil) {
        guard !isBusy else { return }
        thermalStop = !recovery && [.serious, .critical].contains(thermalState())
        guard !thermalStop else { return }
        stopping = false
        restorationFailed = false
        recovering = recovery
        let requested = seconds ?? durationSeconds
        let duration = requested == 0 ? 0 : min(Self.maxSeconds, max(1, requested))
        if !recovery { sessionSeconds = duration }
        manager.run(Command(id: AwakeHelper.daemonID, name: L10n.awakeTitle,
                            command: AwakeHelper.marker, isDaemon: !recovery,
                            env: ["DEVDECK_AWAKE_SECONDS": String(duration),
                                  "DEVDECK_AWAKE_RECOVERY": recovery ? "1" : "0"]))
    }

    func stop() {
        guard isBusy, !recovering, !stopping else { return }
        stopping = true
        manager.stop(AwakeHelper.daemonID)
    }
}
