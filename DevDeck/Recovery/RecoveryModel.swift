import Foundation
import Observation

/// Crash-loop protection (REC-01): reads what the previous process left, switches off modules
/// that keep crashing, and brings them back only on an explicit request.
@MainActor
@Observable
final class RecoveryModel {
    struct Entry: Equatable, Identifiable {
        let module: RecoveryModule
        let suspension: RecoverySuspension
        var id: RecoveryModule { module }
    }

    private(set) var state = RecoveryState()
    /// Called after a module is switched back on, so it starts without a relaunch.
    @ObservationIgnored var onResume: (RecoveryModule) -> Void = { _ in }

    @ObservationIgnored private let storage: any RecoveryStoring
    @ObservationIgnored private let markers: (any RecoveryMarkerStoring)?
    @ObservationIgnored private let bootTime: () -> Int
    @ObservationIgnored private let installedBuild: String
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let notify: ([RecoveryModule]) -> Void
    @ObservationIgnored private var active: [RecoveryOperation: Int] = [:]
    @ObservationIgnored private var launched = false

    init(storage: any RecoveryStoring, markers: (any RecoveryMarkerStoring)?, bootTime: @escaping () -> Int,
         installedBuild: String, now: @escaping () -> Date = Date.init,
         notify: @escaping ([RecoveryModule]) -> Void) {
        self.storage = storage
        self.markers = markers
        self.bootTime = bootTime
        self.installedBuild = installedBuild
        self.now = now
        self.notify = notify
    }

    var hasSuspensions: Bool { !state.suspended.isEmpty }

    var suspensions: [Entry] {
        state.suspended.map { Entry(module: $0.key, suspension: $0.value) }.sorted { $0.module < $1.module }
    }

    func isSuspended(_ module: RecoveryModule) -> Bool { state.suspended[module] != nil }

    /// Once, first thing at launch: judge the previous process and record this one.
    func launch() {
        guard !launched else { return }
        launched = true
        let left = RecoveryOperation.from(mask: markers?.readAndReset() ?? 0)
        let previous = RecoveryState.decode(storage.read())
        let result = RecoveryPolicy.evaluateLaunch(previous, markers: left, bootTime: bootTime(),
                                                   installedBuild: installedBuild, now: now())
        state = result.state
        save()
        if !left.isEmpty {
            DiagnosticLog.shared.log("Recovery: previous process ended inside \(left.map(\.rawValue).sorted())",
                                     level: .warn)
        }
        if !result.newlySuspended.isEmpty {
            DiagnosticLog.shared.log("Recovery: switched off after repeated failures — "
                + result.newlySuspended.map(\.rawValue).joined(separator: ", "), level: .warn)
            notify(result.newlySuspended)
        }
    }

    // MARK: operation markers

    func begin(_ operation: RecoveryOperation) {
        active[operation, default: 0] += 1
        writeMarkers()
    }

    func end(_ operation: RecoveryOperation) {
        guard let count = active[operation] else { return }
        if count <= 1 { active[operation] = nil } else { active[operation] = count - 1 }
        writeMarkers()
        // Finished normally: the series of deaths inside it is broken.
        if state.strikes[operation] != nil {
            state.strikes[operation] = nil
            save()
        }
    }

    func during<T>(_ operation: RecoveryOperation, _ body: () async -> T) async -> T {
        begin(operation)
        defer { end(operation) }
        return await body()
    }

    private func writeMarkers() {
        markers?.write(active.keys.reduce(0) { $0 | $1.bit })
    }

    // MARK: lifecycle

    func markSurvivedEarlyWindow() {
        guard state.lastRun?.survivedEarlyWindow == false else { return }
        state.lastRun?.survivedEarlyWindow = true
        save()
    }

    func markCleanExit() {
        state.lastRun?.cleanExit = true
        save()
    }

    /// Sparkle is about to quit DevDeck and install `build`; the next launch tells whether it did.
    func updateWillInstall(build: String) {
        state.pendingUpdateBuild = build
        save()
    }

    // MARK: explicit return

    func resume(_ module: RecoveryModule) {
        guard state.suspended.removeValue(forKey: module) != nil else { return }
        for operation in RecoveryOperation.allCases where operation.module == module { state.strikes[operation] = nil }
        save()
        DiagnosticLog.shared.log("Recovery: \(module.rawValue) switched back on by the user")
        onResume(module)
    }

    func resumeAll() {
        let modules = suspensions.map(\.module)
        state.earlyUncleanExits = 0
        for module in modules { resume(module) }
        save()
    }

    private func save() {
        guard let data = try? RecoveryState.encode(state) else { return }
        storage.write(data)
    }
}
