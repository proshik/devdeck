import XCTest
@testable import DevDeck

@MainActor
final class CleanupModelTests: XCTestCase {
    private let row = DockerUsageRow(total: 3, active: 1, sizeBytes: 3_000_000_000, reclaimableBytes: 2_000_000_000)
    private var usage: DockerUsage { DockerUsage(images: row, containers: row, volumes: row, buildCache: row) }

    func testRefreshPopulatesEveryHostThatAnswers() async {
        let probe = FakeDockerUsageProbe([.colima: usage])   // minikube down → nil
        let model = CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()), probe: probe)
        XCTAssertTrue(model.usage.isEmpty)

        await model.refresh()

        XCTAssertEqual(model.usage[.colima], usage)
        XCTAssertNil(model.usage[.minikube])
        XCTAssertEqual(Set(probe.calls), Set(DockerHost.allCases))
        XCTAssertFalse(model.isRefreshing)
        XCTAssertEqual(model.estimate(.buildCache, on: .colima), 2_000_000_000)
        XCTAssertNil(model.estimate(.buildCache, on: .minikube))
    }

    func testRefreshReplacesStaleHosts() async {
        let probe = FakeDockerUsageProbe([.colima: usage, .minikube: usage])
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
        let model = CleanupModel(manager: manager, probe: FakeDockerUsageProbe([:]))

        model.restartColima()

        XCTAssertEqual(runner.startedCommandIDs, [CleanupCommands.restartColima.id])
        XCTAssertEqual(model.lastRunID, CleanupCommands.restartColima.id)
        let ctrl = try XCTUnwrap(runner.controller(for: CleanupCommands.restartColima.id))
        ctrl.started(pid: 8)
        await yieldUntil { manager.states[CleanupCommands.restartColima.id] == .running }
        XCTAssertTrue(model.isBusy)
    }
}
