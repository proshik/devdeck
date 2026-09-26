import XCTest
@testable import DevDeck

@MainActor
final class CleanupModelTests: XCTestCase {
    private let row = DockerUsageRow(total: 3, active: 1, sizeBytes: 3_000_000_000, reclaimableBytes: 2_000_000_000)
    private var usage: DockerUsage { DockerUsage(images: row, containers: row, volumes: row, buildCache: row) }

    func testRefreshPopulatesEveryHostThatAnswers() async {
        let probe = FakeDockerUsageProbe([.engineVM: usage])   // minikube down → nil
        let model = CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()), probe: probe)
        XCTAssertTrue(model.usage.isEmpty)

        await model.refresh()

        XCTAssertEqual(model.usage[.engineVM], usage)
        XCTAssertNil(model.usage[.minikube])
        XCTAssertEqual(Set(probe.calls), Set(DockerHost.allCases))
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.estimate(.buildCache, on: .engineVM), 2_000_000_000)
        XCTAssertNil(model.estimate(.buildCache, on: .minikube))
    }

    func testRefreshReplacesStaleHosts() async {
        let probe = FakeDockerUsageProbe([.engineVM: usage, .minikube: usage])
        let model = CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()), probe: probe)
        await model.refresh()
        XCTAssertNotNil(model.usage[.minikube])

        probe.set(nil, for: .minikube)   // cluster stopped between refreshes
        await model.refresh()
        XCTAssertNil(model.usage[.minikube], "a host that stopped answering must not keep stale numbers")
    }

    func testRunStartsTheSyntheticCommandAndLocksTheButtons() async throws {
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        let model = CleanupModel(manager: manager, probe: FakeDockerUsageProbe([:]))
        let id = CleanupCommands.command(.buildCache, on: .minikube, engineName: "colima").id

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
        let model = CleanupModel(manager: manager, probe: FakeDockerUsageProbe([:]))

        model.restartEngine()

        XCTAssertEqual(runner.startedCommandIDs, [CleanupCommands.restartEngineID])
        XCTAssertEqual(model.lastRunID, CleanupCommands.restartEngineID)
        let ctrl = try XCTUnwrap(runner.controller(for: CleanupCommands.restartEngineID))
        ctrl.started(pid: 8)
        await yieldUntil { manager.states[CleanupCommands.restartEngineID] == .running }
        XCTAssertTrue(model.isBusy)
    }

    @MainActor
    func testEngineVMBoxIsShownOnlyUnderColima() {
        let model = CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()),
                                 probe: FakeDockerUsageProbe([:]))
        model.engineKind = { .colima }
        XCTAssertEqual(model.visibleHosts, [.engineVM, .minikube])
        model.engineKind = { .dockerDesktop }
        XCTAssertEqual(model.visibleHosts, [.minikube])
        model.engineKind = { nil }
        XCTAssertEqual(model.visibleHosts, [.minikube])
    }

    @MainActor
    func testRefreshSkipsTheEngineVMOutsideColima() async {
        let probe = FakeDockerUsageProbe([.engineVM: DockerUsage(), .minikube: DockerUsage()])
        let model = CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()), probe: probe)
        model.engineKind = { .dockerDesktop }
        await model.refresh()
        XCTAssertNil(model.usage[.engineVM], "colima ssh must not run under Docker Desktop")
        XCTAssertNotNil(model.usage[.minikube])
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
        let model = CleanupModel(manager: ProcessManager(runner: runner), probe: FakeDockerUsageProbe([.engineVM: u]))
        model.now = { now }
        await model.refresh()

        XCTAssertEqual(model.abandonedTestContainers(on: .engineVM).map(\.id), ["old"])
        model.removeAbandonedTestContainers(on: .engineVM)

        let id = CleanupCommands.testContainersID(on: .engineVM)
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
        let model = CleanupModel(manager: ProcessManager(runner: runner), probe: FakeDockerUsageProbe([.minikube: u]))
        model.now = { now }
        await model.refresh()

        model.removeAbandonedTestContainers(on: .minikube)
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
        XCTAssertNil(model.lastRunID)
    }
}
