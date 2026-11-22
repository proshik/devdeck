import XCTest
@testable import DevDeck

@MainActor
final class CleanupModelTests: XCTestCase {
    private let row = DockerUsageRow(total: 3, active: 1, sizeBytes: 3_000_000_000, reclaimableBytes: 2_000_000_000)
    private var usage: DockerUsage { DockerUsage(images: row, containers: row, volumes: row, buildCache: row) }

    func testRefreshPopulatesEveryHostThatAnswers() async {
        let probe = FakeDockerUsageProbe([.colima: usage])   // minikube down → nil
        let model = CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()), probe: probe, facts: FakeEngineFactsProbe.colimaAndMinikube)
        XCTAssertTrue(model.usage.isEmpty)

        await model.refresh()

        XCTAssertEqual(model.usage[.colima], usage)
        XCTAssertNil(model.usage[.minikube])
        XCTAssertEqual(Set(probe.calls), [.colima, .minikube], "Docker Desktop is not installed in these facts")
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.estimate(.buildCache, on: .colima), 2_000_000_000)
        XCTAssertNil(model.estimate(.buildCache, on: .minikube))
    }

    func testRefreshReplacesStaleHosts() async {
        let probe = FakeDockerUsageProbe([.colima: usage, .minikube: usage])
        let model = CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()), probe: probe, facts: FakeEngineFactsProbe.colimaAndMinikube)
        await model.refresh()
        XCTAssertNotNil(model.usage[.minikube])

        probe.set(nil, for: .minikube)   // cluster stopped between refreshes
        await model.refresh()
        XCTAssertNil(model.usage[.minikube], "a host that stopped answering must not keep stale numbers")
    }

    func testRunStartsTheSyntheticCommandAndLocksTheButtons() async throws {
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        let model = CleanupModel(manager: manager, probe: FakeDockerUsageProbe([:]), facts: FakeEngineFactsProbe.colimaAndMinikube)
        let id = CleanupCommands.command(.buildCache, on: .minikube).id

        model.run(.buildCache, on: .minikube)
        let ctrl = try XCTUnwrap(runner.controller(for: id))
        XCTAssertEqual(runner.startedCommandIDs, [id])
        XCTAssertEqual(model.lastRunID, id)

        ctrl.started(pid: 7)
        await yieldUntil { manager.states[id] == .running }
        XCTAssertTrue(model.isBusy, "one cleanup at a time — they all compete for the same disk")
        XCTAssertEqual(model.state(.buildCache, on: .minikube), .running)

        ctrl.terminate(0)
        await yieldUntil { manager.states[id] == .succeeded }
        XCTAssertFalse(model.isBusy)
    }

    func testRestartColimaGoesThroughTheSameRunner() async throws {
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        let model = CleanupModel(manager: manager, probe: FakeDockerUsageProbe([:]), facts: FakeEngineFactsProbe.colimaAndMinikube)

        model.restartColima()

        XCTAssertEqual(runner.startedCommandIDs, [CleanupCommands.restartEngineID])
        XCTAssertEqual(model.lastRunID, CleanupCommands.restartEngineID)
        let ctrl = try XCTUnwrap(runner.controller(for: CleanupCommands.restartEngineID))
        ctrl.started(pid: 8)
        await yieldUntil { manager.states[CleanupCommands.restartEngineID] == .running }
        XCTAssertTrue(model.isBusy)
    }

    // MARK: - which sections, which probes

    private func facts(colima: (Bool, Bool) = (false, false), desktop: (Bool, Bool) = (false, false),
                       minikube: Bool = false) -> EngineFacts {
        var f = EngineFacts()
        (f.colimaInstalled, f.colimaRunning) = colima
        (f.dockerDesktopInstalled, f.dockerDesktopRunning) = desktop
        f.minikubeInstalled = minikube
        return f
    }

    /// A section per installed engine — running or not, active or not — in page order.
    func testSectionsFollowWhatIsInstalled() async {
        let factsProbe = FakeEngineFactsProbe()
        let model = CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()),
                                 probe: FakeDockerUsageProbe([:]), facts: factsProbe)
        let cases: [(EngineFacts, [DockerHost])] = [
            (facts(), []),
            (facts(colima: (true, true), minikube: true), [.colima, .minikube]),
            (facts(colima: (true, false)), [.colima]),
            (facts(desktop: (true, false)), [.dockerDesktop]),
            (facts(colima: (true, false), desktop: (true, true), minikube: true), [.colima, .dockerDesktop, .minikube]),
        ]
        for (f, expected) in cases {
            factsProbe.facts = f
            await model.refresh()
            XCTAssertEqual(model.visibleHosts, expected, "\(f)")
        }
    }

    /// Only a running engine's daemon is asked — a stopped one gets "not running" and its disk
    /// size, no ssh attempt. minikube is asked whenever it is installed: its answer is its status.
    func testOnlyRunningEnginesAreProbed() async {
        let probe = FakeDockerUsageProbe([.colima: DockerUsage(), .dockerDesktop: DockerUsage(), .minikube: DockerUsage()])
        let model = CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()), probe: probe,
                                 facts: FakeEngineFactsProbe(facts(colima: (true, false), desktop: (true, true), minikube: true)))
        await model.refresh()
        XCTAssertEqual(Set(probe.calls), [.dockerDesktop, .minikube])
        XCTAssertNil(model.usage[.colima])
        XCTAssertFalse(model.isRunning(.colima))
        XCTAssertTrue(model.isRunning(.dockerDesktop))
        XCTAssertTrue(model.isRunning(.minikube), "minikube answered")
    }

    func testMinikubeLivesOnTheEngineThatHoldsItsVolume() async {
        var colima = DockerUsage()
        colima.nestedDaemonVolumeBytes = 45_000_000_000
        var desktop = DockerUsage()
        desktop.nestedDaemonVolumeBytes = 0
        let probe = FakeDockerUsageProbe([.colima: colima, .dockerDesktop: desktop])
        let model = CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()), probe: probe,
                                 facts: FakeEngineFactsProbe(facts(colima: (true, true), desktop: (true, true), minikube: true)))
        await model.refresh()
        XCTAssertEqual(model.minikubeEngine, .colima)

        probe.set(nil, for: .colima)
        await model.refresh()
        XCTAssertNil(model.minikubeEngine)
    }

    // MARK: - test containers left running

    private func testContainer(_ id: String, startedHoursAgo hours: Double, now: Date) -> TestContainer {
        TestContainer(id: id, name: id, image: "postgres:16-alpine",
                      startedAt: now.addingTimeInterval(-hours * 3600), volumes: [])
    }

    func testRemovingTestContainersTakesOnlyTheAbandonedOnes() async throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var u = DockerUsage()
        u.testContainers = [testContainer("old", startedHoursAgo: 50, now: now),
                            testContainer("young", startedHoursAgo: 0.2, now: now)]
        let runner = FakeCommandRunner()
        let model = CleanupModel(manager: ProcessManager(runner: runner), probe: FakeDockerUsageProbe([.colima: u]), facts: FakeEngineFactsProbe.colimaAndMinikube)
        model.now = { now }
        await model.refresh()

        XCTAssertEqual(model.abandonedTestContainers(on: .colima).map(\.id), ["old"])
        model.removeAbandonedTestContainers(on: .colima)

        let id = CleanupCommands.testContainersID(on: .colima)
        XCTAssertEqual(runner.startedCommandIDs, [id])
        XCTAssertEqual(model.lastRunID, id)
        let ctrl = try XCTUnwrap(runner.controller(for: id))
        XCTAssertEqual(ctrl.command.command, "colima ssh -- sh -c 'docker rm -f -v old'")
    }

    func testNothingAbandonedStartsNothing() async {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var u = DockerUsage()
        u.testContainers = [testContainer("young", startedHoursAgo: 0.5, now: now)]
        let runner = FakeCommandRunner()
        let model = CleanupModel(manager: ProcessManager(runner: runner), probe: FakeDockerUsageProbe([.minikube: u]), facts: FakeEngineFactsProbe.colimaAndMinikube)
        model.now = { now }
        await model.refresh()

        model.removeAbandonedTestContainers(on: .minikube)
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
        XCTAssertNil(model.lastRunID)
    }
}
