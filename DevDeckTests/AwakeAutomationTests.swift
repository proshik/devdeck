import XCTest
@testable import DevDeck

/// `DevDeck automation awake …` over the real `AwakeModel` and `ProcessManager` with a fake
/// runner: no administrator prompt, no `pmset`, no root files.
@MainActor
final class AwakeAutomationTests: XCTestCase {

    private var runner: FakeCommandRunner!
    private var model: AwakeModel!
    private var config: Config!
    private var heat = ProcessInfo.ThermalState.nominal
    private var readySince: Date?
    private var now = Date(timeIntervalSince1970: 1_000_000)

    override func setUp() async throws {
        runner = FakeCommandRunner()
        heat = .nominal
        readySince = nil
        now = Date(timeIntervalSince1970: 1_000_000)
        model = AwakeModel(manager: ProcessManager(runner: runner, notifier: FakeNotifier()),
                           hasJournal: { false }, thermalState: { [unowned self] in self.heat },
                           readySince: { [unowned self] in self.readySince })
        config = Config(settings: Settings())
        config.settings.automationEnabled = true
        config.settings.automationAwakeEnabled = true
    }

    private func automation(startWait: Duration = .seconds(5)) -> AwakeAutomation {
        AwakeAutomation(model: model, config: { [unowned self] in self.config }, startWait: startWait,
                        stopWait: .seconds(2), pollInterval: .milliseconds(5), now: { [unowned self] in self.now })
    }

    private func handle(_ action: AutomationAwakeRequest.Action, seconds: Int? = nil,
                        startWait: Duration = .seconds(5)) async -> AutomationResponse {
        await automation(startWait: startWait).handle(AutomationAwakeRequest(action: action, seconds: seconds))
    }

    private func fields(_ response: AutomationResponse) -> [String: String] {
        var fields: [String: String] = [:]
        for line in response.stdout.split(separator: "\n") {
            guard let colon = line.range(of: ": ") else { continue }
            fields[String(line[..<colon.lowerBound])] = String(line[colon.upperBound...])
        }
        return fields
    }

    /// Start `on` and approve it once the helper is launched, as the privileged helper would.
    private func approvedOn(seconds: Int?) async throws -> AutomationResponse {
        let launches = runner.startedCommandIDs.count
        let request = Task { await handle(.on, seconds: seconds) }
        await sleepUntil({ self.runner.startedCommandIDs.count > launches })
        readySince = now
        try XCTUnwrap(runner.controller(for: AwakeHelper.daemonID)).started(pid: nil)
        return await request.value
    }

    func testSwitchesOffRefuseAndStartNothing() async {
        for (master, awake, refusal) in [(false, true, AutomationRefusal.automationDisabled),
                                         (true, false, AutomationRefusal.awakeAutomationDisabled)] {
            config.settings.automationEnabled = master
            config.settings.automationAwakeEnabled = awake
            for action in [AutomationAwakeRequest.Action.on, .off, .status] {
                let response = await handle(action)
                XCTAssertEqual(response.exitCode, AutomationExitCode.refused, "\(action)")
                XCTAssertEqual(response.stderr, refusal.message)
            }
        }
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }

    func testStatusWhenOff() async {
        let response = await handle(.status)
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(fields(response)["status"], "off")
        XCTAssertEqual(fields(response)["durationSeconds"], "7200", "what `on` without --for would use")
        XCTAssertNil(fields(response)["remainingSeconds"])
    }

    func testOnWithDurationPassesItToTheHelperAndReportsRemainingTime() async throws {
        let response = try await approvedOn(seconds: 1800)
        XCTAssertEqual(response.exitCode, AutomationExitCode.success, response.stdout)
        XCTAssertEqual(runner.controller(for: AwakeHelper.daemonID)?.command.env["DEVDECK_AWAKE_SECONDS"], "1800")
        XCTAssertEqual(model.durationSeconds, 7200, "the UI's picker is not moved by the command line")
        XCTAssertEqual(fields(response)["status"], "on")
        XCTAssertEqual(fields(response)["durationSeconds"], "1800")
        XCTAssertEqual(fields(response)["remainingSeconds"], "1800")

        now = now.addingTimeInterval(600)
        let status = await handle(.status)
        XCTAssertEqual(fields(status)["remainingSeconds"], "1200")
        XCTAssertEqual(fields(status)["message"], L10n.automationAwakeOnFor("20m 00s"))
    }

    func testOnWithoutDurationUsesTheUIsChoiceAndZeroIsIndefinite() async throws {
        model.durationSeconds = 3600
        _ = try await approvedOn(seconds: nil)
        XCTAssertEqual(runner.controller(for: AwakeHelper.daemonID)?.command.env["DEVDECK_AWAKE_SECONDS"], "3600")
        _ = await handle(.off)

        let indefinite = try await approvedOn(seconds: 0)
        XCTAssertEqual(runner.controller(for: AwakeHelper.daemonID)?.command.env["DEVDECK_AWAKE_SECONDS"], "0")
        XCTAssertNil(fields(indefinite)["remainingSeconds"])
        XCTAssertEqual(fields(indefinite)["message"], L10n.automationAwakeOnIndefinitely)
    }

    func testOnWhileOnKeepsTheSession() async throws {
        _ = try await approvedOn(seconds: 1800)
        let again = await handle(.on, seconds: 60)
        XCTAssertEqual(again.exitCode, AutomationExitCode.success)
        XCTAssertEqual(runner.startedCommandIDs.count, 1)
        XCTAssertEqual(fields(again)["durationSeconds"], "1800")
        XCTAssertEqual(fields(again)["message"], L10n.automationAwakeAlreadyOn)
    }

    func testCancelledAuthorizationFails() async throws {
        let request = Task { await handle(.on) }
        await sleepUntil({ self.runner.controller(for: AwakeHelper.daemonID) != nil })
        try XCTUnwrap(runner.controller(for: AwakeHelper.daemonID)).cancel()
        let response = await request.value
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed)
        XCTAssertEqual(fields(response)["status"], "off")
        XCTAssertEqual(fields(response)["message"], L10n.automationAwakeCancelled)
    }

    func testRefusingHelperFailsWithItsOutput() async throws {
        let request = Task { await handle(.on) }
        await sleepUntil({ self.runner.controller(for: AwakeHelper.daemonID) != nil })
        let controller = try XCTUnwrap(runner.controller(for: AwakeHelper.daemonID))
        controller.line("Another DevDeck keep-awake session is active.", .stderr)
        controller.terminate(1)
        let response = await request.value
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed)
        XCTAssertEqual(fields(response)["status"], "failed")
        XCTAssertTrue(response.stdout.contains("Another DevDeck keep-awake session is active."))
    }

    func testPendingAuthorizationTimesOutAndKeepsWaiting() async {
        let response = await handle(.on, startWait: .milliseconds(50))
        XCTAssertEqual(response.exitCode, AutomationExitCode.timedOut)
        XCTAssertEqual(fields(response)["status"], "starting")
        XCTAssertTrue(model.isBusy, "the prompt stays open; the wait only gave up")
    }

    func testHotMacIsRefused() async {
        heat = .critical
        let response = await handle(.on)
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(response.stderr, AutomationRefusal.awakeThermal.message)
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }

    func testOffRestoresAndOffWhenOffIsNotAnError() async throws {
        let notRunning = await handle(.off)
        XCTAssertEqual(notRunning.exitCode, AutomationExitCode.success)
        XCTAssertEqual(fields(notRunning)["status"], "off")

        _ = try await approvedOn(seconds: 1800)
        let off = await handle(.off)
        XCTAssertEqual(off.exitCode, AutomationExitCode.success, off.stdout)
        XCTAssertEqual(runner.controller(for: AwakeHelper.daemonID)?.stopCount, 1)
        XCTAssertEqual(fields(off)["status"], "off")
        XCTAssertEqual(fields(off)["message"], L10n.automationAwakeStopped)
    }

    func testRecoveryCannotBeInterrupted() async throws {
        model.start(recovery: true)
        for action in [AutomationAwakeRequest.Action.on, .off] {
            let response = await handle(action)
            XCTAssertEqual(response.exitCode, AutomationExitCode.refused, "\(action)")
            XCTAssertEqual(response.stderr, AutomationRefusal.awakeRecovering.message)
        }
        XCTAssertEqual(runner.controller(for: AwakeHelper.daemonID)?.stopCount, 0)
        runner.controller(for: AwakeHelper.daemonID)?.terminate(0)
    }

    func testOnWhileAuthorizationIsPendingWaitsForTheSameSession() async throws {
        model.start()   // the popover asked; its prompt is open
        let response = Task { await self.handle(.on, seconds: 60) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runner.startedCommandIDs.count, 1, "no second helper")
        readySince = now
        try XCTUnwrap(runner.controller(for: AwakeHelper.daemonID)).started(pid: nil)
        let result = await response.value
        XCTAssertEqual(result.exitCode, AutomationExitCode.success)
        XCTAssertEqual(fields(result)["status"], "on")
    }

    func testOnWhileAuthorizationIsPendingFailsWhenItIsCancelled() async throws {
        model.start()
        let response = Task { await self.handle(.on) }
        try await Task.sleep(for: .milliseconds(50))
        try XCTUnwrap(runner.controller(for: AwakeHelper.daemonID)).cancel()
        let result = await response.value
        XCTAssertEqual(result.exitCode, AutomationExitCode.failed)
    }

    func testAWaitIsNotSatisfiedByASessionStartedAfterItsCancel() async throws {
        let request = Task { await self.handle(.on) }
        await sleepUntil({ self.runner.startedCommandIDs.count == 1 })
        try XCTUnwrap(runner.controller(for: AwakeHelper.daemonID)).cancel()
        await yieldUntil { !self.model.isBusy }
        model.start()   // another session, before the waiting request polls again
        readySince = now
        try XCTUnwrap(runner.controller(for: AwakeHelper.daemonID)).started(pid: nil)
        let response = await request.value
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed, response.stdout)
    }

    func testOffAfterAStartThatFailedBeforeTheHelperIsStillOff() async throws {
        let request = Task { await self.handle(.on) }
        await sleepUntil({ self.runner.startedCommandIDs.count == 1 })
        let controller = try XCTUnwrap(runner.controller(for: AwakeHelper.daemonID))
        controller.line("Cannot create keep-awake lease.", .stderr)
        controller.terminate(1)
        _ = await request.value
        let off = await handle(.off)
        XCTAssertEqual(off.exitCode, AutomationExitCode.success, off.stdout)
    }

    func testOffWithAnUnrestoredJournalIsNotASuccess() async {
        let journaled = AwakeModel(manager: ProcessManager(runner: runner, notifier: FakeNotifier()),
                                   hasJournal: { true })
        let automation = AwakeAutomation(model: journaled, config: { [unowned self] in self.config },
                                         pollInterval: .milliseconds(5))
        let off = await automation.handle(AutomationAwakeRequest(action: .off))
        XCTAssertEqual(off.exitCode, AutomationExitCode.failed)
        XCTAssertEqual(fields(off)["recoveryAvailable"], "yes")
        XCTAssertEqual(fields(off)["message"], L10n.awakeRestoreFailed)
    }

    func testHandMadeDurationsAreValidatedAppSide() async {
        for seconds in [-1, 7201] {
            let response = await handle(.on, seconds: seconds)
            XCTAssertEqual(response.exitCode, AutomationExitCode.usage, "\(seconds)")
        }
        let off = await handle(.off, seconds: 60)
        XCTAssertEqual(off.exitCode, AutomationExitCode.usage)
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }

    func testRouterReachesAwakeAutomation() async {
        let router = AutomationRequestRouter(
            service: AutomationService(manager: model.manager, config: { [unowned self] in self.config }),
            awake: automation())
        let response = await router.handle(AutomationRequest(operation: .awake, awake: .init(action: .status)))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(fields(response)["status"], "off")
    }
}
