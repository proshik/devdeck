import XCTest
@testable import DevDeck

/// The thin CommandRunner adapter over `BuiltInProxyListener`, and the marker-command routing
/// that keeps `ProcessManager` blind to which engine is behind the share daemon.
final class BuiltInProxyRunnerTests: XCTestCase {

    private func markerCommand(configPath: String) -> Command {
        Command(id: ProxyShare.daemonID, name: "Proxy (built-in)",
                command: ProxyShare.builtInCommandPrefix + configPath, isDaemon: true)
    }

    /// Missing config → the same fail-loud shape as `gost -C` on a missing file.
    func testMissingConfigTerminatesWithCode1() async {
        let handle = BuiltInProxyRunner().start(markerCommand(configPath: "/nonexistent/gost.json"))
        var events: [RunnerOutput] = []
        for await event in handle.output { events.append(event) }
        guard case .started = events.first else { return XCTFail("first event must be .started") }
        XCTAssertEqual(events.last, .terminated(exitCode: 1))
        XCTAssertTrue(events.contains { if case .line = $0 { return true }; return false },
                      "the failure must be explained in the log")
    }

    /// End-to-end through the runner: real config file, ephemeral port, stop() → clean exit.
    func testStartsFromConfigFileAndStopsCleanly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let configPath = dir.appendingPathComponent("gost.json").path
        let json = try XCTUnwrap(ProxyShare(port: 0).gostConfigJSON(password: nil))  // port 0 → ephemeral
        try json.write(toFile: configPath, atomically: true, encoding: .utf8)

        let handle = BuiltInProxyRunner().start(markerCommand(configPath: configPath))
        var events: [RunnerOutput] = []
        for await event in handle.output {
            events.append(event)
            if case .started = event { handle.stop(); handle.stop() }   // idempotent
        }
        XCTAssertEqual(events.last, .terminated(exitCode: 0))
        XCTAssertEqual(events.filter { if case .terminated = $0 { return true }; return false }.count, 1)
    }

    func testRoutingDispatchesMarkerToBuiltInRunner() {
        final class Recorder: CommandRunner, @unchecked Sendable {
            private let lock = NSLock()
            private var _started: [Command] = []
            var started: [Command] { lock.lock(); defer { lock.unlock() }; return _started }
            func start(_ command: Command) -> any RunningProcess {
                lock.lock(); _started.append(command); lock.unlock()
                // Any handle satisfies the protocol here — the test only checks the routing.
                return BuiltInProxyRunner().start(command)
            }
        }
        let builtIn = Recorder(), zsh = Recorder(), sudo = Recorder(), terminal = Recorder()
        let router = RoutingCommandRunner(zsh: zsh, sudo: sudo, terminal: terminal, builtInProxy: builtIn)

        _ = router.start(Command(name: "share", command: ProxyShare.builtInCommandPrefix + "/tmp/x.json"))
        _ = router.start(Command(name: "plain", command: "echo hi"))
        _ = router.start(Command(name: "root", command: "echo hi", needsSudo: true))

        XCTAssertEqual(builtIn.started.map(\.name), ["share"])
        XCTAssertEqual(zsh.started.map(\.name), ["plain"])
        XCTAssertEqual(sudo.started.map(\.name), ["root"])
        XCTAssertTrue(terminal.started.isEmpty)
    }
}
