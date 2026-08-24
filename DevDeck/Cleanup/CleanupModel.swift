import Foundation
import Observation

/// State behind the Cleanup page: `docker system df` per daemon, and the cleanup runs themselves,
/// which go through `ProcessManager` like any deck command. Probing is off-main; the model is
/// read on the main actor only.
@MainActor
@Observable
final class CleanupModel {
    /// The last usage snapshot per host; a host that didn't answer is absent (not stale).
    private(set) var usage: [DockerHost: DockerUsage] = [:]
    private(set) var isRefreshing = false
    /// The most recently started cleanup/restart — its log is what the page shows.
    private(set) var lastRunID: UUID?

    @ObservationIgnored private let probe: any DockerUsageProbing
    @ObservationIgnored private let manager: ProcessManager

    init(manager: ProcessManager, probe: any DockerUsageProbing = LiveDockerUsageProbe()) {
        self.manager = manager
        self.probe = probe
    }

    /// Re-read `docker system df` on every host. Overlapping calls collapse into the running one.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let probe = self.probe
        usage = await Task.detached(priority: .utility) {
            var out: [DockerHost: DockerUsage] = [:]
            for host in DockerHost.allCases {
                if let u = probe.sample(host) { out[host] = u }
            }
            return out
        }.value
    }

    func run(_ action: CleanupAction, on host: DockerHost) {
        start(CleanupCommands.command(action, on: host))
    }

    func restartColima() {
        start(CleanupCommands.restartColima)
    }

    private func start(_ command: Command) {
        lastRunID = command.id
        DiagnosticLog.shared.log("Cleanup: \(command.name) — \(command.command)")
        manager.run(command)
    }

    func state(_ action: CleanupAction, on host: DockerHost) -> ProcessManager.RunState? {
        manager.states[CleanupCommands.id(action, on: host)]
    }

    var restartState: ProcessManager.RunState? { manager.states[CleanupCommands.restartColimaID] }

    /// Any cleanup or restart in flight — the buttons lock together, they all compete for one disk.
    var isBusy: Bool {
        CleanupCommands.allIDs.contains { manager.states[$0] == .running }
    }

    func estimate(_ action: CleanupAction, on host: DockerHost) -> UInt64? {
        usage[host]?.estimate(for: action)
    }
}
