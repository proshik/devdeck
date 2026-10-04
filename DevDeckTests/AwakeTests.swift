import XCTest
@testable import DevDeck

/// Fake helper and fake lease: no root, power settings, user files or launched processes.
@MainActor
final class AwakeTests: XCTestCase {
    func testSyntheticDaemonRoutesToAwakeRunner() {
        let awake = FakeCommandRunner()
        let shell = FakeCommandRunner()
        let routing = RoutingCommandRunner(zsh: shell, awake: awake)
        let command = Command(id: AwakeHelper.daemonID, name: "awake", command: AwakeHelper.marker, isDaemon: true)
        _ = routing.start(command)
        XCTAssertEqual(awake.startedCommandIDs, [command.id])
        XCTAssertTrue(shell.startedCommandIDs.isEmpty)
    }

    func testAuthorizationStartDoesNotReportSleepDisabled() async throws {
        let helper = FakeCommandRunner()
        let command = Command(name: "helper", command: "fake")
        let lease = FakeAwakeLease()
        let owner = UUID()
        let process = AwakeProcess(lease: lease, owner: owner) { helper.start(command) }
        let events = AwakeEvents()
        let consumer = Task { for await event in process.output { events.items.append(event) } }
        let controller = try XCTUnwrap(helper.controller(for: command.id))
        controller.started()
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(events.items.isEmpty, "Authorization is not readiness")
        lease.readyOwner = UUID()
        process.pollReady()
        XCTAssertTrue(events.items.isEmpty, "Another instance's receipt cannot activate this one")
        lease.readyOwner = owner
        process.pollReady()
        await yieldUntil { events.items == [.started(pid: nil)] }
        XCTAssertEqual(events.items, [.started(pid: nil)])
        controller.terminate(0)
        await consumer.value
        XCTAssertEqual(events.items, [.started(pid: nil), .terminated(exitCode: 0)])
    }

    func testStopRevokesLeaseAndWaitsForRestorationWithoutKillingHelper() async throws {
        let helper = FakeCommandRunner()
        let command = Command(name: "helper", command: "fake")
        let lease = FakeAwakeLease()
        let process = AwakeProcess(lease: lease, owner: UUID()) { helper.start(command) }
        let controller = try XCTUnwrap(helper.controller(for: command.id))
        let events = AwakeEvents()
        let consumer = Task { for await event in process.output { events.items.append(event) } }
        process.stop()
        XCTAssertFalse(lease.exists)
        XCTAssertEqual(controller.stopCount, 0, "Killing the helper could strand SleepDisabled")
        for _ in 0..<30 { await Task.yield() }
        XCTAssertTrue(events.items.isEmpty, "Stop does not claim restoration until the helper exits")
        controller.terminate(0)
        await consumer.value
        XCTAssertEqual(events.items.last, .terminated(exitCode: 0))
    }

    func testLeaseFailureNeverRequestsPrivileges() async {
        let lease = FakeAwakeLease()
        lease.createSucceeds = false
        var launched = false
        let fake = FakeCommandRunner()
        let process = AwakeProcess(lease: lease, owner: UUID()) {
            launched = true
            return fake.start(Command(name: "fake", command: "fake"))
        }
        var events: [RunnerOutput] = []
        for await event in process.output { events.append(event) }
        XCTAssertFalse(launched)
        XCTAssertEqual(events.first, .line("Cannot create keep-awake lease.", stream: .stderr))
        XCTAssertEqual(events.last, .terminated(exitCode: 1))
    }

    func testCancelledAuthorizationFinishesAndRemovesLease() async throws {
        let helper = FakeCommandRunner()
        let command = Command(name: "helper", command: "fake")
        let lease = FakeAwakeLease()
        let process = AwakeProcess(lease: lease, owner: UUID()) { helper.start(command) }
        try XCTUnwrap(helper.controller(for: command.id)).cancel()
        var events: [RunnerOutput] = []
        for await event in process.output { events.append(event) }
        XCTAssertEqual(events, [.cancelled])
        XCTAssertFalse(lease.exists)
    }

    func testModelPreventsDuplicateRunsAndThermalPressureRevokesLease() async throws {
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        var heat = ProcessInfo.ThermalState.nominal
        let model = AwakeModel(manager: manager, hasJournal: { false }, thermalState: { heat })
        model.start()
        model.start()
        XCTAssertEqual(runner.startedCommandIDs.count, 1)
        let controller = try XCTUnwrap(runner.controller(for: AwakeHelper.daemonID))
        XCTAssertTrue(controller.command.isDaemon)
        XCTAssertFalse(controller.command.needsSudo, "Privilege lifecycle belongs to the adapter")
        controller.started(pid: nil)
        await yieldUntil { model.isActive }
        heat = .serious
        model.refresh()
        XCTAssertTrue(model.stopping)
        XCTAssertTrue(model.thermalStop)
        XCTAssertEqual(controller.stopCount, 1)
        await yieldUntil { model.state == .idle }
        model.refresh()
        XCTAssertFalse(model.stopping)
    }

    func testHotMacRefusesNewLeaseButStillAllowsSleepRecovery() {
        let runner = FakeCommandRunner()
        let model = AwakeModel(manager: ProcessManager(runner: runner), hasJournal: { true },
                               thermalState: { .critical })
        model.start()
        XCTAssertTrue(model.thermalStop)
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
        model.start(recovery: true)
        XCTAssertEqual(runner.startedCommandIDs, [AwakeHelper.daemonID])
        runner.controller(for: AwakeHelper.daemonID)?.terminate(0)
    }

    func testRecoveryOnHotMacCannotBeCancelledOrHideRestoreFailure() async throws {
        let runner = FakeCommandRunner()
        let model = AwakeModel(manager: ProcessManager(runner: runner), hasJournal: { true },
                               thermalState: { .critical })
        model.start(recovery: true)
        let controller = try XCTUnwrap(runner.controller(for: AwakeHelper.daemonID))
        model.refresh()
        model.stop()
        XCTAssertFalse(model.thermalStop, "Restoring sleep is permitted under thermal pressure")
        XCTAssertFalse(model.stopping)
        XCTAssertEqual(controller.stopCount, 0, "A restore must run through to its real result")
        controller.line("restore failed", .stderr)
        controller.terminate(1)
        await yieldUntil { model.state == .failed(code: 1) }
        XCTAssertEqual(model.state, .failed(code: 1), "A recovery error must not become a user stop")
        XCTAssertEqual(model.error, "restore failed")
        model.refresh()
        XCTAssertTrue(model.recoveryAvailable)
    }

    func testNeverReadyHelperCannotNotifyDaemonStarted() async throws {
        for code: Int32? in [nil, 1, 3] {
            let helper = FakeCommandRunner()
            let command = Command(name: "helper", command: "fake")
            let process = AwakeProcess(lease: FakeAwakeLease(), owner: UUID()) { helper.start(command) }
            let notifier = FakeNotifier()
            let model = AwakeModel(manager: ProcessManager(runner: FixedAwakeRunner(handle: process),
                                                            notifier: notifier), hasJournal: { false })
            model.start()
            let controller = try XCTUnwrap(helper.controller(for: command.id))
            controller.started()
            if let code {
                controller.line("helper refused", .stderr)
                controller.terminate(code)
                await yieldUntil { model.state == .failed(code: code) }
                XCTAssertEqual(notifier.posted, [.daemonFailedToStart(name: L10n.awakeTitle, code: code)])
                XCTAssertEqual(model.error, "helper refused")
            } else {
                controller.cancel()
                await yieldUntil { model.state == .idle }
                XCTAssertTrue(notifier.posted.isEmpty, "Cancelling authorization never means the daemon started")
            }
            XCTAssertFalse(model.isActive)
        }
    }

    func testStopRestorationFailureRemainsVisibleAndDoesNotClaimThermalShutdown() async throws {
        for thermalCutoff in [false, true] {
            let runner = FakeCommandRunner()
            runner.autoTerminateOnStopCode = nil
            var journal = false
            var heat = ProcessInfo.ThermalState.nominal
            let model = AwakeModel(manager: ProcessManager(runner: runner), hasJournal: { journal },
                                   thermalState: { heat })
            model.start()
            let controller = try XCTUnwrap(runner.controller(for: AwakeHelper.daemonID))
            controller.started(pid: nil)
            await yieldUntil { model.isActive }
            journal = true
            if thermalCutoff { heat = .critical; model.refresh() } else { model.stop() }
            controller.line("Sleep restoration failed.", .stderr)
            controller.terminate(1)
            await yieldUntil { model.state == .idle }
            model.refresh()
            XCTAssertTrue(model.recoveryAvailable)
            XCTAssertTrue(model.error?.contains("Sleep restoration failed.") ?? false,
                          "The neutral ProcessManager state must not hide a restoration failure")
            XCTAssertFalse(model.thermalStop, "Do not claim sleep was restored while its journal remains")
            journal = false
            model.refresh()
            XCTAssertNil(model.error, "An externally completed recovery clears the warning")
        }
    }

    func testRecoveryIsOfferedForUnrestoredJournalAndUsesOneShotCommand() throws {
        let runner = FakeCommandRunner()
        let model = AwakeModel(manager: ProcessManager(runner: runner), hasJournal: { true })
        model.refresh()
        XCTAssertTrue(model.recoveryAvailable)
        model.start(recovery: true)
        let controller = try XCTUnwrap(runner.controller(for: AwakeHelper.daemonID))
        XCTAssertFalse(controller.command.isDaemon)
        XCTAssertEqual(controller.command.env["DEVDECK_AWAKE_RECOVERY"], "1")
        controller.terminate(0)
    }
}

@MainActor
private final class AwakeEvents { var items: [RunnerOutput] = [] }

private final class FakeAwakeLease: AwakeLease, @unchecked Sendable {
    let url = URL(fileURLWithPath: "/unused/fake-lease")
    private let lock = NSLock()
    private var _exists = false
    private var _readyOwner: UUID?
    var createSucceeds = true
    var exists: Bool { lock.lock(); defer { lock.unlock() }; return _exists }
    var readyOwner: UUID? {
        get { lock.lock(); defer { lock.unlock() }; return _readyOwner }
        set { lock.lock(); _readyOwner = newValue; lock.unlock() }
    }
    func create() -> Bool { lock.lock(); defer { lock.unlock() }; _exists = createSucceeds; return _exists }
    func remove() -> Bool { lock.lock(); defer { lock.unlock() }; _exists = false; return true }
    func isReady(owner: UUID) -> Bool { readyOwner == owner }
}

private struct FixedAwakeRunner: CommandRunner {
    let handle: any RunningProcess
    func start(_ command: Command) -> any RunningProcess { handle }
}
