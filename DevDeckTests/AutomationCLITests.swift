import XCTest
@testable import DevDeck

/// Stage 8, iteration 2: the `DevDeck automation …` command line. Argument parsing, the wire
/// format, exit codes and the client side of a call are pure; the socket itself is covered by
/// `AutomationSocketTests`.
final class AutomationCLIParsingTests: XCTestCase {

    private let devDir = "/Users/someone/dev-data"

    private func parse(_ args: [String], cwd: String = "/Users/someone/project", development: Bool = false,
                       info: [String: Any] = [:]) -> Result<AutomationCLI.Invocation, AutomationCLI.UsageError> {
        AutomationCLI.parse(args, currentDirectory: cwd, isDevelopmentBuild: development, bundleInfo: info)
    }

    private func request(_ args: [String], cwd: String = "/Users/someone/project") -> AutomationRequest? {
        guard case .success(.request(let request, _)) = parse(args, cwd: cwd) else { return nil }
        return request
    }

    private func usage(_ args: [String], development: Bool = false, info: [String: Any] = [:]) -> String? {
        guard case .failure(let error) = parse(args, development: development, info: info) else { return nil }
        return error.message
    }

    func testList() {
        XCTAssertEqual(request(["list"]), AutomationRequest(operation: .list))
    }

    func testRunCommandByNameWithDefaults() {
        XCTAssertEqual(request(["run", "command", "echo"]),
                       AutomationRequest(operation: .run, kind: .command, target: "echo"))
    }

    func testNameWithSpacesIsOneArgument() {
        XCTAssertEqual(request(["status", "chain", "restart colima"])?.target, "restart colima")
    }

    func testRunChainWithTimeout() {
        XCTAssertEqual(request(["run", "chain", "deploy", "--timeout", "60"]),
                       AutomationRequest(operation: .run, kind: .chain, target: "deploy", timeoutSeconds: 60))
    }

    func testStopAndStatus() {
        XCTAssertEqual(request(["stop", "command", "pf"]), AutomationRequest(operation: .stop, kind: .command, target: "pf"))
        XCTAssertEqual(request(["status", "chain", "c"]), AutomationRequest(operation: .status, kind: .chain, target: "c"))
    }

    func testDirectoryIsResolvedAgainstTheCallersDirectory() {
        XCTAssertEqual(request(["run", "command", "claude", "--directory", "."], cwd: "/Users/someone/project")?.directory,
                       "/Users/someone/project")
        XCTAssertEqual(request(["run", "command", "claude", "--directory", "../other/"], cwd: "/Users/someone/project")?.directory,
                       "/Users/someone/other")
        XCTAssertEqual(request(["run", "command", "claude", "--directory", "/abs/path"])?.directory, "/abs/path")
        XCTAssertEqual(request(["run", "command", "claude", "--directory", "~/x"])?.directory,
                       (("~/x" as NSString).expandingTildeInPath as NSString).standardizingPath)
    }

    func testHelp() {
        for args in [["help"], ["--help"], ["-h"], ["run", "--help"]] {
            guard case .success(.help) = parse(args) else { return XCTFail("\(args) should print help") }
        }
    }

    func testUsageErrors() {
        XCTAssertNotNil(usage([]), "no operation")
        XCTAssertNotNil(usage(["launch", "command", "x"]), "unknown operation")
        XCTAssertNotNil(usage(["run", "script", "x"]), "unknown kind")
        XCTAssertNotNil(usage(["run", "command"]), "missing target")
        XCTAssertNotNil(usage(["run", "command", "a", "b"]), "extra argument")
        XCTAssertNotNil(usage(["list", "x"]), "list takes no target")
        XCTAssertNotNil(usage(["run", "command", "a", "--force"]), "unknown option")
        XCTAssertNotNil(usage(["run", "command", "a", "--timeout"]), "option without a value")
        XCTAssertNotNil(usage(["run", "command", "a", "--timeout", "soon"]), "non-numeric timeout")
        XCTAssertNotNil(usage(["run", "command", "a", "--timeout", "0"]), "timeout below the range")
        XCTAssertNotNil(usage(["run", "command", "a", "--timeout", "3601"]), "timeout above the range")
        XCTAssertNotNil(usage(["run", "chain", "a", "--directory", "/x"]), "a chain takes no directory")
        XCTAssertNotNil(usage(["stop", "command", "a", "--timeout", "5"]), "stop takes no timeout")
        XCTAssertNotNil(usage(["status", "command", "a", "--directory", "/x"]), "status takes no directory")
        XCTAssertNotNil(usage(["run", "command", "  "]), "blank target")
    }

    func testTimeoutBoundsAreTheSharedLimits() {
        XCTAssertEqual(request(["run", "command", "a", "--timeout", "\(AutomationLimits.minTimeoutSeconds)"])?.timeoutSeconds, 1)
        XCTAssertEqual(request(["run", "command", "a", "--timeout", "\(AutomationLimits.maxTimeoutSeconds)"])?.timeoutSeconds, 3600)
    }

    // MARK: development builds never reach the installed DevDeck

    func testDevelopmentBuildRequiresDevDataDirectory() {
        XCTAssertNotNil(usage(["list"], development: true))
        guard case .success(.request(_, let directory)) = parse(["list", "--dev-data-directory", devDir], development: true)
        else { return XCTFail("a development build with a data directory must parse") }
        XCTAssertEqual(directory, devDir)
    }

    func testDevDataDirectoryMayComeFirst() {
        guard case .success(.request(let request, let directory)) =
                parse(["--dev-data-directory", devDir, "run", "command", "echo"], development: true)
        else { return XCTFail("leading option must parse") }
        XCTAssertEqual(request.target, "echo")
        XCTAssertEqual(directory, devDir)
    }

    func testDevDataDirectoryMustBeAbsoluteAndSeparate() {
        XCTAssertNotNil(usage(["list", "--dev-data-directory", "relative/dir"], development: true))
        let installed = AutomationEndpoint.installedDataDirectory.path
        XCTAssertNotNil(usage(["list", "--dev-data-directory", installed], development: true))
    }

    // MARK: the packaged data directory (Info.plist), so a bare launch of the binary stays isolated

    private var packaged: [String: Any] { [AppRuntime.developmentDirectoryInfoKey: "/Users/someone/packaged"] }

    func testDevelopmentBuildUsesThePackagedDataDirectory() {
        guard case .success(.request(_, let directory)) = parse(["list"], development: true, info: packaged)
        else { return XCTFail("the packaged directory stands in for the flag") }
        XCTAssertEqual(directory, "/Users/someone/packaged")
    }

    func testFlagWinsOverThePackagedDataDirectory() {
        guard case .success(.request(_, let directory)) =
                parse(["list", "--dev-data-directory", devDir], development: true, info: packaged)
        else { return XCTFail("flag must parse") }
        XCTAssertEqual(directory, devDir)
    }

    func testInvalidPackagedDataDirectoryIsAUsageError() {
        XCTAssertNotNil(usage(["list"], development: true, info: [AppRuntime.developmentDirectoryInfoKey: "relative"]))
    }

    func testReleaseBuildIgnoresThePackagedDataDirectory() {
        guard case .success(.request(_, let directory)) = parse(["list"], development: false, info: packaged)
        else { return XCTFail("a release build parses without a data directory") }
        XCTAssertNil(directory, "release behaviour does not change")
    }

    func testReleaseBuildRejectsDevDataDirectory() {
        XCTAssertNotNil(usage(["list", "--dev-data-directory", devDir], development: false))
        guard case .success(.request(_, let directory)) = parse(["list"], development: false)
        else { return XCTFail("a release build needs no data directory") }
        XCTAssertNil(directory)
    }
}

final class AutomationWireTests: XCTestCase {

    func testRequestRoundTrip() throws {
        let request = AutomationRequest(operation: .run, kind: .command, target: "echo",
                                        directory: "/tmp", timeoutSeconds: 12)
        let data = try AutomationWire.encode(request)
        XCTAssertEqual(data.last, UInt8(ascii: "\n"), "one JSON line")
        XCTAssertEqual(data.filter { $0 == UInt8(ascii: "\n") }.count, 1)
        XCTAssertEqual(try AutomationWire.decodeRequest(data), request)
    }

    func testResponseRoundTripKeepsNewlinesInsideTheLine() throws {
        let response = AutomationResponse(exitCode: 1, stdout: "status: failed\nexitCode: 2", stderr: "")
        let data = try AutomationWire.encode(response)
        XCTAssertEqual(data.filter { $0 == UInt8(ascii: "\n") }.count, 1)
        XCTAssertEqual(try AutomationWire.decodeResponse(data), response)
    }

    func testGarbageIsRejected() {
        XCTAssertThrowsError(try AutomationWire.decodeRequest(Data("hello\n".utf8)))
        XCTAssertThrowsError(try AutomationWire.decodeRequest(Data(#"{"operation":"format-disk"}"#.utf8)))
        XCTAssertThrowsError(try AutomationWire.decodeResponse(Data("{}".utf8)))
    }

    func testEndpointSeparatesBuildsAndDataDirectories() {
        let dir = URL(fileURLWithPath: "/Users/someone/data")
        let prod = AutomationEndpoint.socketName(bundleID: "com.proshik.DevDeck", dataDirectory: dir)
        XCTAssertEqual(prod, AutomationEndpoint.socketName(bundleID: "com.proshik.DevDeck",
                                                           dataDirectory: URL(fileURLWithPath: "/Users/someone/data/")),
                       "a trailing slash names the same directory")
        XCTAssertNotEqual(prod, AutomationEndpoint.socketName(bundleID: "com.proshik.DevDeck.stage7.acceptance", dataDirectory: dir))
        XCTAssertNotEqual(prod, AutomationEndpoint.socketName(bundleID: "com.proshik.DevDeck",
                                                              dataDirectory: URL(fileURLWithPath: "/Users/someone/other")))
        XCTAssertTrue(prod.hasPrefix("automation-") && prod.hasSuffix(".sock"))
        XCTAssertLessThanOrEqual(AutomationEndpoint.socketURL(bundleID: "com.proshik.DevDeck.stage7.acceptance",
                                                              dataDirectory: dir).path.utf8.count,
                                 AutomationEndpoint.maxPathBytes, "fits sun_path for a normal home")
    }
}

final class AutomationExitCodeTests: XCTestCase {

    private func code(_ status: AutomationReport.Status, _ operation: AutomationOperation) -> Int32 {
        AutomationExitCode.code(for: AutomationReport(status: status, kind: .command, name: "x", id: UUID(),
                                                      state: "idle", message: ""), operation: operation)
    }

    func testConstantsAreDistinct() {
        let all: [Int32] = [AutomationExitCode.success, AutomationExitCode.failed, AutomationExitCode.timedOut,
                            AutomationExitCode.refused, AutomationExitCode.appNotRunning,
                            AutomationExitCode.communication, AutomationExitCode.usage]
        XCTAssertEqual(Set(all).count, all.count)
        XCTAssertEqual(AutomationExitCode.success, 0)
    }

    func testRunCodes() {
        for status: AutomationReport.Status in [.succeeded, .running, .alreadyRunning, .openedInTerminal] {
            XCTAssertEqual(code(status, .run), AutomationExitCode.success, "\(status)")
        }
        XCTAssertEqual(code(.failed, .run), AutomationExitCode.failed)
        XCTAssertEqual(code(.stopped, .run), AutomationExitCode.failed, "a cancelled sudo prompt did not run")
        XCTAssertEqual(code(.timedOut, .run), AutomationExitCode.timedOut)
    }

    func testStopCodes() {
        XCTAssertEqual(code(.stopped, .stop), AutomationExitCode.success)
        XCTAssertEqual(code(.notRunning, .stop), AutomationExitCode.success)
        XCTAssertEqual(code(.running, .stop), AutomationExitCode.timedOut, "still running after the stop wait")
    }

    func testStatusIsAlwaysSuccess() {
        for status: AutomationReport.Status in [.failed, .running, .idle, .timedOut, .succeeded] {
            XCTAssertEqual(code(status, .status), AutomationExitCode.success)
        }
    }
}

/// The client half of a call with the transport faked out.
final class AutomationCLIExecutionTests: XCTestCase {

    private func execute(_ args: [String], development: Bool = false,
                         send: @escaping AutomationCLI.Sender) -> AutomationCLI.Outcome {
        AutomationCLI.execute(args, currentDirectory: "/tmp", isDevelopmentBuild: development, bundleInfo: [:],
                              bundleID: "com.proshik.DevDeck", send: send)
    }

    func testResponseIsPassedThrough() {
        var sent: AutomationRequest?
        var socket: URL?
        let outcome = execute(["run", "command", "echo"]) { request, url, _ in
            sent = request
            socket = url
            return .success(AutomationResponse(exitCode: 0, stdout: "status: succeeded", stderr: ""))
        }
        XCTAssertEqual(outcome, AutomationCLI.Outcome(code: 0, stdout: "status: succeeded\n", stderr: ""))
        XCTAssertEqual(sent?.target, "echo")
        XCTAssertEqual(socket, AutomationEndpoint.socketURL(bundleID: "com.proshik.DevDeck",
                                                            dataDirectory: AutomationEndpoint.installedDataDirectory))
    }

    func testRefusalGoesToStderr() {
        let outcome = execute(["run", "command", "nope"]) { _, _, _ in
            .success(AutomationResponse(exitCode: AutomationExitCode.refused, stdout: "", stderr: "no such command"))
        }
        XCTAssertEqual(outcome, AutomationCLI.Outcome(code: AutomationExitCode.refused, stdout: "", stderr: "no such command\n"))
    }

    func testAppNotRunning() {
        let outcome = execute(["list"]) { _, _, _ in .failure(.notRunning) }
        XCTAssertEqual(outcome.code, AutomationExitCode.appNotRunning)
        XCTAssertTrue(outcome.stdout.isEmpty)
        XCTAssertFalse(outcome.stderr.isEmpty)
    }

    func testCommunicationFailure() {
        let outcome = execute(["list"]) { _, _, _ in .failure(.communication("connection reset")) }
        XCTAssertEqual(outcome.code, AutomationExitCode.communication)
        XCTAssertTrue(outcome.stderr.contains("connection reset"))
    }

    func testUsageErrorSendsNothing() {
        var called = false
        let outcome = execute(["run", "command"]) { _, _, _ in called = true; return .failure(.notRunning) }
        XCTAssertFalse(called)
        XCTAssertEqual(outcome.code, AutomationExitCode.usage)
        XCTAssertFalse(outcome.stderr.isEmpty)
    }

    func testHelpDescribesExitCodesAndThePath() {
        let outcome = execute(["--help"]) { _, _, _ in XCTFail("help sends nothing"); return .failure(.notRunning) }
        XCTAssertEqual(outcome.code, AutomationExitCode.success)
        for code in [AutomationExitCode.failed, AutomationExitCode.timedOut, AutomationExitCode.refused,
                     AutomationExitCode.appNotRunning, AutomationExitCode.communication, AutomationExitCode.usage] {
            XCTAssertTrue(outcome.stdout.contains(" \(code) "), "help lists exit code \(code)")
        }
        XCTAssertTrue(outcome.stdout.contains("/Applications/DevDeck.app/Contents/MacOS/DevDeck"))
    }

    func testDevelopmentBuildTalksToItsOwnDataDirectory() {
        var socket: URL?
        _ = execute(["list", "--dev-data-directory", "/Users/someone/dev"], development: true) { _, url, _ in
            socket = url
            return .success(AutomationResponse(exitCode: 0, stdout: "", stderr: ""))
        }
        XCTAssertEqual(socket, AutomationEndpoint.socketURL(bundleID: "com.proshik.DevDeck",
                                                            dataDirectory: URL(fileURLWithPath: "/Users/someone/dev")))
        XCTAssertNotEqual(socket, AutomationEndpoint.socketURL(bundleID: "com.proshik.DevDeck",
                                                               dataDirectory: AutomationEndpoint.installedDataDirectory))
    }

    func testRunWaitsLongerThanItsTimeout() {
        var wait: TimeInterval?
        _ = execute(["run", "command", "x", "--timeout", "100"]) { _, _, timeout in
            wait = timeout
            return .failure(.notRunning)
        }
        XCTAssertGreaterThan(wait ?? 0, 100)
    }
}

/// The app side: a request goes through `AutomationService` over the real `ProcessManager` state
/// machine with a fake runner — no processes, no sockets.
@MainActor
final class AutomationRequestRouterTests: XCTestCase {

    private var runner: FakeCommandRunner!
    private var manager: ProcessManager!
    private var config: Config!

    override func setUp() async throws {
        runner = FakeCommandRunner()
        manager = ProcessManager(runner: runner, notifier: FakeNotifier(), appController: FakeAppController(),
                                 reaper: FakeDaemonReaper(), portInspector: FakePortInspector(),
                                 hostMonitoringEnabled: { false })
        config = Config(settings: Settings())
        config.settings.automationEnabled = true
    }

    private func router() -> AutomationRequestRouter {
        AutomationRequestRouter(service: AutomationService(
            manager: manager, config: { [unowned self] in self.config }, portInspector: FakePortInspector(),
            directories: FakeDirectoryProbe(), pollInterval: .milliseconds(2), stopWait: .milliseconds(300)))
    }

    @discardableResult
    private func add(_ name: String, _ command: String = "true", allowed: Bool = true,
                     openInTerminal: Bool = false, needsSudo: Bool = false) -> Command {
        let c = Command(name: name, command: command, needsSudo: needsSudo, openInTerminal: openInTerminal,
                        allowAutomation: allowed)
        config.commands.append(c)
        return c
    }

    private func run(_ target: String, kind: AutomationReport.Kind = .command, timeout: Int? = 5) async -> AutomationResponse {
        await router().handle(AutomationRequest(operation: .run, kind: kind, target: target, timeoutSeconds: timeout))
    }

    func testRunByNameSucceeds() async {
        let c = add("echo", "echo hello")
        runner.eagerScripts[c.id] = [.started(pid: 3), .line("hello", stream: .stdout), .terminated(exitCode: 0)]

        let response = await run("echo")

        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertTrue(response.stdout.contains("status: succeeded"))
        XCTAssertTrue(response.stdout.hasSuffix("hello"))
        XCTAssertEqual(response.stderr, "")
    }

    func testRunByUUIDIgnoresCase() async {
        let c = add("echo")
        runner.eagerScripts[c.id] = [.started(pid: 3), .terminated(exitCode: 0)]
        let response = await run(c.id.uuidString.lowercased())
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
    }

    func testRepeatedRunDoesNotStartTwice() async {
        let c = add("slow", "sleep 100")
        let router = router()
        let first = await router.handle(AutomationRequest(operation: .run, kind: .command, target: "slow", timeoutSeconds: 1))
        let second = await router.handle(AutomationRequest(operation: .run, kind: .command, target: "slow", timeoutSeconds: 1))

        XCTAssertEqual(first.exitCode, AutomationExitCode.timedOut)
        XCTAssertTrue(first.stdout.contains("status: timedOut"))
        XCTAssertEqual(second.exitCode, AutomationExitCode.success)
        XCTAssertTrue(second.stdout.contains("status: alreadyRunning"))
        XCTAssertEqual(runner.startedCommandIDs, [c.id])
    }

    func testFailedRunExitsWithFailed() async {
        let c = add("test", "make test")
        runner.eagerScripts[c.id] = [.started(pid: 3), .terminated(exitCode: 2)]
        let response = await run("test")
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed)
        XCTAssertTrue(response.stdout.contains("exitCode: 2"))
    }

    func testCancelledSudoPromptIsAFailure() async {
        let c = add("flush", "dscacheutil -flushcache", needsSudo: true)
        runner.eagerScripts[c.id] = [.cancelled]
        let response = await run("flush")
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed)
        XCTAssertTrue(response.stdout.contains("status: stopped"))
    }

    func testTerminalCommandReportsOpenedInTerminal() async {
        let c = add("claude", "claude", openInTerminal: true)
        runner.eagerScripts[c.id] = [.started(pid: 3)]
        let response = await run("claude")
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertTrue(response.stdout.contains("status: openedInTerminal"))
    }

    func testUnknownNameIsRefused() async {
        add("echo")
        let response = await run("ech")
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertTrue(response.stderr.contains("ech"))
        XCTAssertEqual(response.stdout, "")
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }

    func testAmbiguousNameListsTheIDs() async {
        let a = add("build")
        let b = add("build")
        let response = await run("build")
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertTrue(response.stderr.contains(a.id.uuidString))
        XCTAssertTrue(response.stderr.contains(b.id.uuidString))
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }

    func testNotAllowedCommandIsRefused() async {
        add("deploy", "make deploy", allowed: false)
        let response = await run("deploy")
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(response.stderr, AutomationRefusal.commandNotAllowed("deploy").message)
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }

    func testDisabledAutomationRefusesEverything() async {
        add("echo")
        config.settings.automationEnabled = false
        let run = await run("echo")
        let list = await router().handle(AutomationRequest(operation: .list))
        XCTAssertEqual(run.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(run.stderr, AutomationRefusal.automationDisabled.message)
        XCTAssertEqual(list.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(list.stdout, "")
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }

    func testListShowsOnlyAllowedItems() async {
        let echo = add("echo")
        add("secret", allowed: false)
        let chain = Chain(name: "restart colima", commandIDs: [echo.id], allowAutomation: true)
        config.chains = [chain, Chain(name: "hidden", commandIDs: [])]

        let response = await router().handle(AutomationRequest(operation: .list))

        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(response.stdout, "command\t\(echo.id.uuidString)\techo\nchain\t\(chain.id.uuidString)\trestart colima")
    }

    func testChainRunReportsFailedStep() async {
        let a = add("lint")
        let b = add("test")
        runner.eagerScripts[a.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        runner.eagerScripts[b.id] = [.started(pid: 2), .terminated(exitCode: 1)]
        config.chains = [Chain(name: "ci", commandIDs: [a.id, b.id], allowAutomation: true)]

        let response = await run("ci", kind: .chain)

        XCTAssertEqual(response.exitCode, AutomationExitCode.failed)
        XCTAssertTrue(response.stdout.contains("failedStep: 2"))
    }

    func testStopAndStatus() async {
        add("idle")
        let stop = await router().handle(AutomationRequest(operation: .stop, kind: .command, target: "idle"))
        let status = await router().handle(AutomationRequest(operation: .status, kind: .command, target: "idle"))
        XCTAssertEqual(stop.exitCode, AutomationExitCode.success)
        XCTAssertTrue(stop.stdout.contains("status: notRunning"))
        XCTAssertEqual(status.exitCode, AutomationExitCode.success)
        XCTAssertTrue(status.stdout.contains("status: idle"))
    }

    func testIncompleteRequestIsAUsageError() async {
        let response = await router().handle(AutomationRequest(operation: .run))
        XCTAssertEqual(response.exitCode, AutomationExitCode.usage)
        XCTAssertFalse(response.stderr.isEmpty)
    }

    func testForeignVersionIsRejectedWithoutAction() async {
        add("echo")
        var request = AutomationRequest(operation: .run, kind: .command, target: "echo")
        request.version = 99
        let response = await router().handle(request)
        XCTAssertEqual(response.exitCode, AutomationExitCode.communication)
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }
}
