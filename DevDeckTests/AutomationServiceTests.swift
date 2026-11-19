import XCTest
@testable import DevDeck

/// Fake directory table — no real file system.
final class FakeDirectoryProbe: DirectoryProbe, @unchecked Sendable {
    var existing: Set<String> = []
    func isDirectory(atPath path: String) -> Bool { existing.contains(path) }
}

/// Stage 8: external automation of saved commands and chains (App Intents / Shortcuts).
/// The service runs over the real `ProcessManager` state machine with a fake runner, a fake
/// port table and a fake directory probe — no processes, no lsof, no Shortcuts.
@MainActor
final class AutomationServiceTests: XCTestCase {

    private var runner: FakeCommandRunner!
    private var inspector: FakePortInspector!
    private var directories: FakeDirectoryProbe!
    private var manager: ProcessManager!
    private var config: Config!

    override func setUp() async throws {
        runner = FakeCommandRunner()
        inspector = FakePortInspector()
        directories = FakeDirectoryProbe()
        manager = ProcessManager(runner: runner, notifier: FakeNotifier(), appController: FakeAppController(),
                                 reaper: FakeDaemonReaper(), portInspector: inspector,
                                 hostMonitoringEnabled: { false })
        config = Config(settings: Settings())
        config.settings.automationEnabled = true
    }

    private func service() -> AutomationService {
        AutomationService(manager: manager, config: { [unowned self] in self.config },
                          portInspector: inspector, directories: directories,
                          pollInterval: .milliseconds(2), stopWait: .milliseconds(500))
    }

    @discardableResult
    private func add(_ command: Command, allowed: Bool = true) -> Command {
        var command = command
        command.allowAutomation = allowed
        config.commands.append(command)
        return command
    }

    @discardableResult
    private func add(_ chain: Chain, allowed: Bool = true) -> Chain {
        var chain = chain
        chain.allowAutomation = allowed
        config.chains.append(chain)
        return chain
    }

    private func refusal(_ body: () async throws -> AutomationReport) async -> AutomationRefusal? {
        do {
            let report = try await body()
            XCTFail("expected a refusal, got \(report.status)")
            return nil
        } catch let refusal as AutomationRefusal {
            return refusal
        } catch {
            XCTFail("unexpected error \(error)")
            return nil
        }
    }

    // MARK: access

    func testDisabledAutomationRefusesAndUIStillRuns() async {
        let c = add(Command(name: "build", command: "make"))
        config.settings.automationEnabled = false
        let s = service()

        let error = await refusal { try await s.runCommand(c.id, directory: nil, timeout: .seconds(1)) }
        XCTAssertEqual(error, .automationDisabled)
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
        let stopError = await refusal { try await s.stopCommand(c.id) }
        XCTAssertEqual(stopError, .automationDisabled)
        XCTAssertThrowsError(try s.commandStatus(c.id))
        XCTAssertTrue(s.availableCommands().isEmpty, "nothing is offered to Shortcuts while disabled")

        manager.run(c)   // the regular UI path is untouched
        XCTAssertEqual(runner.startedCommandIDs, [c.id])
    }

    func testNotAllowedCommandAndChainAreRefused() async {
        let c = add(Command(name: "secret", command: "rm -rf x"), allowed: false)
        let chain = add(Chain(name: "deploy", commandIDs: [c.id]), allowed: false)
        let s = service()

        let commandError = await refusal { try await s.runCommand(c.id, directory: nil, timeout: .seconds(1)) }
        XCTAssertEqual(commandError, .commandNotAllowed("secret"))
        let chainError = await refusal { try await s.runChain(chain.id, timeout: .seconds(1)) }
        XCTAssertEqual(chainError, .chainNotAllowed("deploy"))
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }

    func testUnknownUUIDIsRefused() async {
        let s = service()
        let ghost = UUID()
        let commandError = await refusal { try await s.runCommand(ghost, directory: nil, timeout: .seconds(1)) }
        XCTAssertEqual(commandError, .commandNotFound(ghost))
        let chainError = await refusal { try await s.runChain(ghost, timeout: .seconds(1)) }
        XCTAssertEqual(chainError, .chainNotFound(ghost))
        XCTAssertThrowsError(try s.chainStatus(ghost)) { XCTAssertEqual($0 as? AutomationRefusal, .chainNotFound(ghost)) }
    }

    func testOnlyAllowedItemsAreOffered() {
        let allowed = add(Command(name: "a", command: "true"))
        add(Command(name: "b", command: "true"), allowed: false)
        let chain = add(Chain(name: "c"))
        add(Chain(name: "d"), allowed: false)
        let s = service()
        XCTAssertEqual(s.availableCommands().map(\.id), [allowed.id])
        XCTAssertEqual(s.availableChains().map(\.id), [chain.id])
    }

    // MARK: one-shot commands

    func testOneShotSucceedsWithBoundedOutputTail() async throws {
        let c = add(Command(name: "build", command: "make"))
        runner.eagerScripts[c.id] = [.started(pid: 7)]
            + (1...40).map { .line("line \($0)", stream: .stdout) }
            + [.terminated(exitCode: 0)]

        let report = try await service().runCommand(c.id, directory: nil, timeout: .seconds(5))

        XCTAssertEqual(report.status, .succeeded)
        XCTAssertEqual(report.exitCode, 0)
        XCTAssertEqual(report.output.count, AutomationLimits.outputLines)
        XCTAssertEqual(report.output.last, "line 40")
        XCTAssertEqual(report.output.first, "line 11")
    }

    func testOneShotFailureCarriesExitCode() async throws {
        let c = add(Command(name: "test", command: "make test"))
        runner.eagerScripts[c.id] = [.started(pid: 7), .line("boom", stream: .stderr), .terminated(exitCode: 2)]

        let report = try await service().runCommand(c.id, directory: nil, timeout: .seconds(5))

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.exitCode, 2)
        XCTAssertEqual(report.output, ["boom"])
    }

    func testOneShotTimeoutLeavesCommandRunning() async throws {
        let c = add(Command(name: "slow", command: "sleep 100"))

        let report = try await service().runCommand(c.id, directory: nil, timeout: .milliseconds(60))

        XCTAssertEqual(report.status, .timedOut)
        XCTAssertEqual(manager.states[c.id], .running, "a timeout is not a cancellation")
        XCTAssertEqual(runner.controller(for: c.id)?.stopCount, 0)
    }

    func testRepeatedRunDoesNotStartTwice() async throws {
        let c = add(Command(name: "slow", command: "sleep 100"))
        let s = service()
        _ = try await s.runCommand(c.id, directory: nil, timeout: .milliseconds(20))   // timed out, still running

        let again = try await s.runCommand(c.id, directory: nil, timeout: .seconds(5))

        XCTAssertEqual(again.status, .alreadyRunning)
        XCTAssertEqual(again.state, "running")
        XCTAssertEqual(runner.startedCommandIDs, [c.id], "a repeated request must not start a second run")
    }

    func testConcurrentRequestsStartOnce() async throws {
        let c = add(Command(name: "slow", command: "sleep 100"))
        let s = service()
        async let first = s.runCommand(c.id, directory: nil, timeout: .milliseconds(80))
        async let second = s.runCommand(c.id, directory: nil, timeout: .milliseconds(80))
        let statuses = Set([try await first.status, try await second.status])

        XCTAssertEqual(statuses, [.timedOut, .alreadyRunning])
        XCTAssertEqual(runner.startedCommandIDs, [c.id])
    }

    func testCancelledSudoPromptReportsStopped() async throws {
        let c = add(Command(name: "flush", command: "dscacheutil -flushcache", needsSudo: true))
        runner.eagerScripts[c.id] = [.cancelled]

        let report = try await service().runCommand(c.id, directory: nil, timeout: .seconds(5))

        XCTAssertEqual(report.status, .stopped)
    }

    func testSudoDaemonIsRefused() async {
        let c = add(Command(name: "root pf", command: "x", isDaemon: true, needsSudo: true))
        let error = await refusal { try await self.service().runCommand(c.id, directory: nil, timeout: .seconds(1)) }
        XCTAssertEqual(error, .sudoDaemonUnsupported("root pf"))
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }

    func testTerminalCommandReportsOpenedInTerminal() async throws {
        let c = add(Command(name: "claude", command: "claude", openInTerminal: true))

        let report = try await service().runCommand(c.id, directory: nil, timeout: .seconds(5))

        XCTAssertEqual(report.status, .openedInTerminal)
        XCTAssertEqual(runner.startedCommandIDs, [c.id])
    }

    func testAppsToQuitStillApply() async throws {
        let apps = FakeAppController()
        apps.willQuit = ["com.example.heavy"]
        manager = ProcessManager(runner: runner, notifier: FakeNotifier(), appController: apps,
                                 reaper: FakeDaemonReaper(), portInspector: inspector,
                                 hostMonitoringEnabled: { false })
        let c = add(Command(name: "build", command: "make",
                            appsToQuit: [AppRef(bundleID: "com.example.heavy", name: "Heavy")]))
        runner.eagerScripts[c.id] = [.started(pid: 1), .terminated(exitCode: 0)]

        let report = try await service().runCommand(c.id, directory: nil, timeout: .seconds(5))

        XCTAssertEqual(report.status, .succeeded)
        XCTAssertEqual(apps.quitCalls, [["com.example.heavy"]])
        await yieldUntil { apps.relaunchCalls == [["com.example.heavy"]] }
    }

    // MARK: directory

    func testDirectoryCommandRequiresAnExistingDirectory() async throws {
        let c = add(Command(name: "claude", command: "claude", workingDirectory: "/stored", promptForDirectory: true))
        let s = service()

        let missing = await refusal { try await s.runCommand(c.id, directory: nil, timeout: .seconds(1)) }
        XCTAssertEqual(missing, .directoryRequired("claude"))
        let absent = await refusal { try await s.runCommand(c.id, directory: "/nope", timeout: .seconds(1)) }
        XCTAssertEqual(absent, .directoryMissing("/nope"))
        let relative = await refusal { try await s.runCommand(c.id, directory: "src", timeout: .seconds(1)) }
        XCTAssertEqual(relative, .directoryMissing("src"))
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)

        directories.existing = ["/work/project"]
        runner.eagerScripts[c.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        let report = try await s.runCommand(c.id, directory: "/work/project", timeout: .seconds(5))

        XCTAssertEqual(report.status, .succeeded)
        XCTAssertEqual(report.directory, "/work/project")
        XCTAssertEqual(runner.controller(for: c.id)?.command.workingDirectory, "/work/project", "a copy runs there")
        XCTAssertEqual(config.commands.first?.workingDirectory, "/stored", "the saved command is untouched")
    }

    func testDirectoryIsRejectedForACommandThatDoesNotAskForOne() async {
        let c = add(Command(name: "build", command: "make", workingDirectory: "/repo"))
        directories.existing = ["/other"]
        let error = await refusal { try await self.service().runCommand(c.id, directory: "/other", timeout: .seconds(1)) }
        XCTAssertEqual(error, .directoryNotAccepted("build"))
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }

    // MARK: daemons

    func testDaemonReportsRunningOnceUp() async throws {
        let c = add(Command(name: "pf", command: "kubectl port-forward", isDaemon: true, port: 8080))
        runner.eagerScripts[c.id] = [.started(pid: 9)]

        let report = try await service().runCommand(c.id, directory: nil, timeout: .seconds(5))

        XCTAssertEqual(report.status, .running)
        XCTAssertEqual(report.state, "daemonRunning")
        XCTAssertEqual(manager.states[c.id], .daemonRunning)
    }

    func testOccupiedPortIsRefusedWithOwnerAndNoPanel() async {
        let c = add(Command(name: "pf", command: "kubectl port-forward", isDaemon: true, port: 8080))
        inspector.occupants[8080] = PortOccupant(pid: 555, processName: "python3")

        let error = await refusal { try await self.service().runCommand(c.id, directory: nil, timeout: .seconds(1)) }

        XCTAssertEqual(error, .portOccupied(port: 8080, process: "python3", pid: 555))
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
        XCTAssertNil(manager.portConflicts[c.id], "automation offers no kill panel")
    }

    func testDaemonFailureReportsPortOwner() async throws {
        let c = add(Command(name: "pf", command: "kubectl port-forward", isDaemon: true, port: 8080))
        let s = service()
        let pending = Task { try await s.runCommand(c.id, directory: nil, timeout: .seconds(5)) }
        await sleepUntil { self.runner.controller(for: c.id) != nil }
        inspector.occupants[8080] = PortOccupant(pid: 77, processName: "ssh")
        runner.controller(for: c.id)?.terminate(1)

        let report = try await pending.value

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.exitCode, 1)
        XCTAssertEqual(report.port, 8080)
        XCTAssertEqual(report.portOccupant, PortOccupant(pid: 77, processName: "ssh"))
    }

    func testProxyUnavailableIsRefused() async {
        let c = add(Command(name: "curl", command: "curl x", routeThroughProxy: true))
        manager.proxyRouting = { _ in .unavailable }
        let error = await refusal { try await self.service().runCommand(c.id, directory: nil, timeout: .seconds(1)) }
        XCTAssertEqual(error, .proxyUnavailable("curl"))
    }

    // MARK: stop / status

    func testStopRunningDaemonAndNotRunning() async throws {
        let c = add(Command(name: "pf", command: "kubectl port-forward", isDaemon: true))
        runner.eagerScripts[c.id] = [.started(pid: 9)]
        let s = service()
        _ = try await s.runCommand(c.id, directory: nil, timeout: .seconds(5))

        let stopped = try await s.stopCommand(c.id)
        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertEqual(manager.states[c.id], .idle)

        let again = try await s.stopCommand(c.id)
        XCTAssertEqual(again.status, .notRunning)
    }

    func testCommandStatusReportsStateAndOutput() async throws {
        let c = add(Command(name: "build", command: "make"))
        let s = service()
        XCTAssertEqual(try s.commandStatus(c.id).status, .idle)

        runner.eagerScripts[c.id] = [.started(pid: 1), .line("done", stream: .stdout), .terminated(exitCode: 4)]
        _ = try await s.runCommand(c.id, directory: nil, timeout: .seconds(5))
        let status = try s.commandStatus(c.id)

        XCTAssertEqual(status.status, .failed)
        XCTAssertEqual(status.exitCode, 4)
        XCTAssertEqual(status.output, ["done"])
    }

    // MARK: chains

    func testChainReportsFailedStep() async throws {
        let a = add(Command(name: "fetch", command: "git fetch"), allowed: false)   // the chain's grant covers it
        let b = add(Command(name: "test", command: "make test"), allowed: false)
        let chain = add(Chain(name: "ci", commandIDs: [a.id, b.id]))
        runner.eagerScripts[a.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        runner.eagerScripts[b.id] = [.started(pid: 2), .line("FAIL", stream: .stderr), .terminated(exitCode: 3)]

        let report = try await service().runChain(chain.id, timeout: .seconds(5))

        XCTAssertEqual(report.status, .failed)
        XCTAssertEqual(report.failedStep, 2)
        XCTAssertEqual(report.failedStepName, "test")
        XCTAssertEqual(report.exitCode, 3)
        XCTAssertEqual(report.output, ["FAIL"])
    }

    func testChainSucceeds() async throws {
        let a = add(Command(name: "a", command: "true"))
        let chain = add(Chain(name: "ok", commandIDs: [a.id]))
        runner.eagerScripts[a.id] = [.started(pid: 1), .terminated(exitCode: 0)]

        let report = try await service().runChain(chain.id, timeout: .seconds(5))
        XCTAssertEqual(report.status, .succeeded)
    }

    func testChainTimeoutKeepsRunningAndIsNotRestarted() async throws {
        let a = add(Command(name: "slow", command: "sleep 100"))
        let chain = add(Chain(name: "long", commandIDs: [a.id]))
        let s = service()

        let report = try await s.runChain(chain.id, timeout: .milliseconds(40))
        XCTAssertEqual(report.status, .timedOut)
        XCTAssertEqual(report.currentStep, 1)
        XCTAssertEqual(report.currentStepName, "slow")
        XCTAssertEqual(manager.chainStates[chain.id], .running(currentIndex: 0))

        let again = try await s.runChain(chain.id, timeout: .seconds(5))
        XCTAssertEqual(again.status, .alreadyRunning)
        XCTAssertEqual(runner.startedCommandIDs, [a.id])

        let stopped = try await s.stopChain(chain.id)
        XCTAssertEqual(stopped.status, .stopped)
        XCTAssertEqual(manager.chainStates[chain.id], .stopped)
        XCTAssertEqual(try s.chainStatus(chain.id).status, .stopped)
        let notRunning = try await s.stopChain(chain.id)
        XCTAssertEqual(notRunning.status, .notRunning)
    }

    func testTerminalChainReportsOpenedInTerminal() async throws {
        let a = add(Command(name: "a", command: "true"))
        let chain = add(Chain(name: "tab", commandIDs: [a.id], openInTerminal: true))

        let report = try await service().runChain(chain.id, timeout: .seconds(5))
        XCTAssertEqual(report.status, .openedInTerminal)
        XCTAssertEqual(runner.startedCommandIDs, [chain.id])
    }

    // MARK: report format and limits

    func testReportRendersKeyValueLines() {
        let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
        let report = AutomationReport(status: .failed, kind: .chain, name: "ci", id: id, state: "failed",
                                      exitCode: 3, failedStep: 2, failedStepName: "test",
                                      message: "Step 2 failed", output: ["a", "b"])
        XCTAssertEqual(report.text, """
            status: failed
            kind: chain
            name: ci
            id: 11111111-2222-3333-4444-555555555555
            state: failed
            exitCode: 3
            failedStep: 2
            failedStepName: test
            message: Step 2 failed
            output (last 2 lines):
            a
            b
            """)
    }

    func testTimeoutIsClampedToLimits() {
        XCTAssertEqual(AutomationLimits.timeout(seconds: nil), .seconds(AutomationLimits.defaultTimeoutSeconds))
        XCTAssertEqual(AutomationLimits.timeout(seconds: 0), .seconds(AutomationLimits.minTimeoutSeconds))
        XCTAssertEqual(AutomationLimits.timeout(seconds: 999_999), .seconds(AutomationLimits.maxTimeoutSeconds))
        XCTAssertEqual(AutomationLimits.timeout(seconds: 42), .seconds(42))
    }

    func testIntentTimeoutDefaultsMatchTheLimits() {
        XCTAssertEqual(RunDevDeckCommandIntent().timeoutSeconds, AutomationLimits.defaultTimeoutSeconds)
        XCTAssertEqual(RunDevDeckChainIntent().timeoutSeconds, AutomationLimits.defaultTimeoutSeconds)
        XCTAssertEqual(AutomationLimits.minTimeoutSeconds, 1, "repeated as a literal in the intents' inclusiveRange")
        XCTAssertEqual(AutomationLimits.maxTimeoutSeconds, 3600, "repeated as a literal in the intents' inclusiveRange")
    }

    func testTextQueryMatchesNameOrID() {
        let id = UUID()
        XCTAssertTrue(DevDeckCommandQuery.matches(id, "Port forward", "port"))
        XCTAssertTrue(DevDeckCommandQuery.matches(id, "Port forward", " \(id.uuidString.lowercased()) "))
        XCTAssertFalse(DevDeckCommandQuery.matches(id, "Port forward", "build"))
    }

    func testRefusalMessagesAreLocalizedAndSpecific() {
        XCTAssertTrue(AutomationRefusal.portOccupied(port: 8080, process: "python3", pid: 555).message.contains("8080"))
        XCTAssertTrue(AutomationRefusal.portOccupied(port: 8080, process: "python3", pid: 555).message.contains("python3"))
        let id = UUID()
        XCTAssertTrue(AutomationRefusal.commandNotFound(id).message.contains(id.uuidString))
    }

    // MARK: config

    func testNewConfigFieldsDecodeWithDefaultsAndRoundTrip() throws {
        let legacy = Data(#"{"commands":[{"name":"a","command":"true"}],"chains":[{"name":"c"}],"settings":{}}"#.utf8)
        let decoded = try JSONDecoder().decode(Config.self, from: legacy)
        XCTAssertFalse(decoded.settings.automationEnabled)
        XCTAssertFalse(decoded.commands[0].allowAutomation)
        XCTAssertFalse(decoded.chains[0].allowAutomation)
        XCTAssertEqual(decoded.schemaVersion, Config.currentSchemaVersion)

        var changed = decoded
        changed.settings.automationEnabled = true
        changed.commands[0].allowAutomation = true
        changed.chains[0].allowAutomation = true
        let again = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(changed))
        XCTAssertEqual(again, changed)
    }

    func testAutomationSwitchPersists() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")
        let store = CommandStore(configURL: url)
        store.setAutomationEnabled(true)

        let reloaded = try JSONDecoder().decode(Config.self, from: Data(contentsOf: url))
        XCTAssertTrue(reloaded.settings.automationEnabled)
    }
}
