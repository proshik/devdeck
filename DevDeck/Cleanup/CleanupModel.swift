import Foundation
import Observation

/// State behind the Cleanup page's engine sections: which engines are installed and running,
/// `docker system df` per daemon, and the cleanup runs themselves, which go through
/// `ProcessManager` like any deck command. Probing is off-main; the model is read on the main
/// actor only. The Mac-disk part (`DiskOverviewModel`) runs its deletion through `start` here, so
/// the page has one "last action" log and one busy lock.
@MainActor
@Observable
final class CleanupModel {
    /// The last usage snapshot per host; a host that didn't answer is absent (not stale).
    private(set) var usage: [DockerHost: DockerUsage] = [:]
    /// Installed / running / disk files, re-read on every refresh.
    private(set) var facts = EngineFacts()
    private(set) var isRefreshing = false
    /// The most recently started cleanup/restart/deletion — its log is what the page shows.
    private(set) var lastRunID: UUID?

    @ObservationIgnored private let probe: any DockerUsageProbing
    @ObservationIgnored private let factsProbe: any EngineFactsProbing
    @ObservationIgnored private let manager: ProcessManager

    /// The clock a test container's age is measured against — injected by tests.
    @ObservationIgnored var now: () -> Date = Date.init

    /// A section per installed engine, not only the active one: the page answers "what takes the
    /// disk", and a stopped engine's VM disk still takes it.
    var visibleHosts: [DockerHost] {
        DockerHost.displayOrder.filter { facts.isInstalled($0) }
    }

    /// Whether the section can show figures and buttons. minikube counts as running when its
    /// probe answered — `minikube ssh` failing is the only cheap "stopped" it has.
    func isRunning(_ host: DockerHost) -> Bool {
        switch host {
        case .colima: return facts.colimaRunning
        case .dockerDesktop: return facts.dockerDesktopRunning
        case .minikube: return usage[.minikube] != nil
        }
    }

    /// The engine whose disk holds the minikube node: the one whose docker lists the node's
    /// volume (`created_by.minikube.sigs.k8s.io`). nil when neither does.
    var minikubeEngine: DockerHost? {
        [DockerHost.colima, .dockerDesktop].first { (usage[$0]?.nestedDaemonVolumeBytes ?? 0) > 0 }
    }

    init(manager: ProcessManager, probe: any DockerUsageProbing = LiveDockerUsageProbe(),
         facts: any EngineFactsProbing = LiveEngineFactsProbe()) {
        self.manager = manager
        self.probe = probe
        self.factsProbe = facts
    }

    /// Re-read the engines, then `docker system df` on every running one. Overlapping calls
    /// collapse into the running one.
    func refresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }
        let probe = self.probe, factsProbe = self.factsProbe
        let (facts, usage) = await Task.detached(priority: .utility) { () -> (EngineFacts, [DockerHost: DockerUsage]) in
            let facts = factsProbe.sample()
            var out: [DockerHost: DockerUsage] = [:]
            for host in DockerHost.displayOrder where facts.shouldProbe(host) {
                if let u = probe.sample(host) { out[host] = u }
            }
            return (facts, out)
        }.value
        if facts != self.facts { self.facts = facts }
        self.usage = usage
    }

    func run(_ action: CleanupAction, on host: DockerHost) {
        start(CleanupCommands.command(action, on: host))
    }

    func abandonedTestContainers(on host: DockerHost) -> [TestContainer] {
        usage[host]?.abandonedTestContainers(now: now()) ?? []
    }

    func abandonedTestContainerBytes(on host: DockerHost) -> UInt64? {
        usage[host]?.abandonedTestContainerBytes(now: now())
    }

    /// Removes what the page last showed as abandoned; nothing to remove → nothing starts.
    func removeAbandonedTestContainers(on host: DockerHost) {
        let ids = abandonedTestContainers(on: host).map(\.id)
        guard !ids.isEmpty else { return }
        start(CleanupCommands.removeTestContainers(ids: ids, on: host))
    }

    func testContainersState(on host: DockerHost) -> ProcessManager.RunState? {
        manager.states[CleanupCommands.testContainersID(on: host)]
    }

    func restartColima() {
        start(CleanupCommands.restartColima())
    }

    /// Every cleanup goes through here: it becomes the page's "last action" and runs on the
    /// shared runner.
    func start(_ command: Command) {
        lastRunID = command.id
        DiagnosticLog.shared.log("Cleanup: \(command.name) — \(command.command)")
        manager.run(command)
    }

    func state(_ action: CleanupAction, on host: DockerHost) -> ProcessManager.RunState? {
        manager.states[CleanupCommands.id(action, on: host)]
    }

    func state(of id: UUID) -> ProcessManager.RunState? { manager.states[id] }

    var restartState: ProcessManager.RunState? { manager.states[CleanupCommands.restartEngineID] }

    /// Any cleanup, restart or deletion in flight — the buttons lock together, they all compete
    /// for one disk.
    var isBusy: Bool {
        CleanupCommands.allIDs.contains { manager.states[$0] == .running }
    }

    func estimate(_ action: CleanupAction, on host: DockerHost) -> UInt64? {
        usage[host]?.estimate(for: action)
    }
}
