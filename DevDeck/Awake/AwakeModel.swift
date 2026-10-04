import Foundation
import Observation

@MainActor @Observable
final class AwakeModel {
    let manager: ProcessManager
    var durationSeconds = 7200
    private(set) var stopping = false
    private(set) var recovering = false
    private(set) var recoveryAvailable = false
    private(set) var thermalStop = false
    private var restorationFailed = false
    @ObservationIgnored private let hasJournal: () -> Bool
    @ObservationIgnored private let thermalState: () -> ProcessInfo.ThermalState
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(manager: ProcessManager,
         hasJournal: @escaping () -> Bool = { FileManager.default.fileExists(atPath: AwakeHelper.journalURL.path) },
         thermalState: @escaping () -> ProcessInfo.ThermalState = { ProcessInfo.processInfo.thermalState }) {
        self.manager = manager
        self.hasJournal = hasJournal
        self.thermalState = thermalState
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

    func start(recovery: Bool = false) {
        guard !isBusy else { return }
        thermalStop = !recovery && [.serious, .critical].contains(thermalState())
        guard !thermalStop else { return }
        stopping = false
        restorationFailed = false
        recovering = recovery
        manager.run(Command(id: AwakeHelper.daemonID, name: L10n.awakeTitle,
                            command: AwakeHelper.marker, isDaemon: !recovery,
                            env: ["DEVDECK_AWAKE_SECONDS": String(min(7200, max(1, durationSeconds))),
                                  "DEVDECK_AWAKE_RECOVERY": recovery ? "1" : "0"]))
    }

    func stop() {
        guard isBusy, !recovering, !stopping else { return }
        stopping = true
        manager.stop(AwakeHelper.daemonID)
    }
}
