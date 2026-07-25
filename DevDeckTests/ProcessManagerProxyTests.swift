import XCTest
@testable import DevDeck

/// The injection point: `startRun` is the single `runner.start` call site, so overlaying the proxy
/// env there covers zsh, sudo and terminal runs alike (they all read `command.env`).
@MainActor
final class ProcessManagerProxyTests: XCTestCase {

    private func flagged(_ name: String = "claude") -> Command {
        Command(id: UUID(), name: name, command: "claude", routeThroughProxy: true)
    }

    private let routedEnv = proxyEnv(host: "192.168.1.42", port: 9999, user: nil, pass: nil)

    func testRoutedCommandStartsWithTheProxyEnv() async {
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        manager.proxyRouting = { _ in .routed(env: self.routedEnv) }
        let command = flagged()

        manager.run(command)
        let started = try! XCTUnwrap(runner.controller(for: command.id)?.command)

        XCTAssertEqual(started.env["HTTPS_PROXY"], "http://192.168.1.42:9999")
        XCTAssertEqual(started.env["https_proxy"], "http://192.168.1.42:9999")
        XCTAssertEqual(started.env["NO_PROXY"], "localhost,127.0.0.1,::1")
    }

    func testProxyEnvWinsOverTheCommandsOwnValue() {
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        manager.proxyRouting = { _ in .routed(env: self.routedEnv) }
        var command = flagged()
        command.env = ["HTTPS_PROXY": "http://stale:1", "MY_VAR": "keep"]

        manager.run(command)
        let started = try! XCTUnwrap(runner.controller(for: command.id)?.command)

        XCTAssertEqual(started.env["HTTPS_PROXY"], "http://192.168.1.42:9999", "the live proxy overrides a stale value")
        XCTAssertEqual(started.env["MY_VAR"], "keep", "unrelated variables survive")
    }

    func testUnavailableProxyFailsTheRunWithoutStartingIt() async {
        let runner = FakeCommandRunner()
        let notifier = FakeNotifier()
        let manager = ProcessManager(runner: runner, notifier: notifier)
        manager.proxyRouting = { _ in .unavailable }
        let command = flagged("claude")

        manager.run(command)

        XCTAssertTrue(runner.startedCommandIDs.isEmpty,
                      "never launch it unprotected — that would leak past the VPN")
        XCTAssertEqual(manager.states[command.id], .failed(code: ProcessManager.proxyUnavailableCode))
        XCTAssertEqual(notifier.posted, [.proxyUnavailable(name: "claude")])
        let log = manager.logs[command.id]?.elements.map(\.text) ?? []
        XCTAssertEqual(log, [L10n.proxyUnavailable], "the reason is visible in the command's log")
    }

    func testUnflaggedCommandIsUntouchedEvenWhenNoProxyExists() {
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        manager.proxyRouting = { _ in .unavailable }   // would fail a FLAGGED command
        let plain = Command(id: UUID(), name: "build", command: "just build", env: ["A": "b"])

        manager.run(plain)
        let started = try! XCTUnwrap(runner.controller(for: plain.id)?.command)

        XCTAssertEqual(started.env, ["A": "b"], "commands without the flag run exactly as before")
        XCTAssertEqual(manager.states[plain.id], .running)
    }

    func testRoutingIsNotConsultedForUnflaggedCommands() {
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        var consulted = 0
        manager.proxyRouting = { _ in consulted += 1; return .notRouted }

        manager.run(Command(id: UUID(), name: "build", command: "just build"))

        XCTAssertEqual(consulted, 0, "no proxy resolution work for the common case")
    }

    func testDefaultRoutingLeavesFlaggedCommandsAlone() {
        // No AppDelegate wiring (as in every other test): the default closure is `.notRouted`,
        // so an un-wired ProcessManager can't accidentally fail commands.
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        let command = flagged()

        manager.run(command)

        XCTAssertEqual(runner.startedCommandIDs, [command.id])
        XCTAssertEqual(manager.states[command.id], .running)
    }

    func testUnavailableProxyFailsAChainStepAndStopsTheChain() async {
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        manager.proxyRouting = { command in command.routeThroughProxy ? .unavailable : .notRouted }
        let first = Command(id: UUID(), name: "a", command: "echo")
        let second = flagged("b")
        runner.eagerScripts[first.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        let chain = Chain(id: UUID(), name: "c", commandIDs: [first.id, second.id], stopOnError: true)

        manager.run(chain, commands: [first.id: first, second.id: second])
        await yieldUntil {
            if case .failed = manager.chainStates[chain.id] { return true }
            return false
        }

        XCTAssertEqual(runner.startedCommandIDs, [first.id], "the routed step never launched")
        XCTAssertEqual(manager.states[second.id], .failed(code: ProcessManager.proxyUnavailableCode))
    }

    func testRoutedDaemonKeepsItsSupervisionBehaviour() async {
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        manager.proxyRouting = { _ in .routed(env: self.routedEnv) }
        var daemon = flagged("tunnelled daemon")
        daemon.isDaemon = true
        daemon.watchdogEnabled = true

        manager.run(daemon)
        runner.controller(for: daemon.id)?.started(pid: 7)
        await yieldUntil { manager.states[daemon.id] == .daemonRunning }

        XCTAssertEqual(manager.watchdogPhases[daemon.id], .armed)
        XCTAssertEqual(runner.controller(for: daemon.id)?.command.env["HTTPS_PROXY"],
                       "http://192.168.1.42:9999")
    }
}
