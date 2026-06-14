import XCTest
@testable import DevDeck

/// Integration: `ProcessManager` on top of the REAL `RoutingCommandRunner` (live processes).
/// Covers the wiring that was absent from unit tests (which use a fake runner) — this is
/// exactly where the off-main crash surfaced at Stage 3.
@MainActor
final class ProcessManagerRealRunnerTests: XCTestCase {

    /// Waits up to timeout by actually sleeping (events arrive in real time from background queues).
    private func waitReal(_ timeout: TimeInterval = 6, _ condition: () -> Bool) async throws {
        let start = Date()
        while !condition() {
            if Date().timeIntervalSince(start) > timeout { return }
            try await Task.sleep(nanoseconds: 25_000_000)
        }
    }

    func testRealEchoThroughManagerSucceeds() async throws {
        let manager = ProcessManager()
        let command = Command(id: UUID(), name: "e", command: "echo hi")

        manager.run(command)
        try await waitReal { manager.states[command.id] == .succeeded }

        XCTAssertEqual(manager.states[command.id], .succeeded)
        XCTAssertTrue(manager.logs[command.id]?.elements.contains(LogLine(text: "hi", stream: .stdout)) ?? false)
    }

    func testRealFailingCommandThroughManagerFails() async throws {
        let manager = ProcessManager()
        let command = Command(id: UUID(), name: "f", command: "ls /no-such-xyz-\(UUID().uuidString)")

        manager.run(command)
        try await waitReal { if case .failed = manager.states[command.id] { return true }; return false }

        guard case .failed = manager.states[command.id] else {
            return XCTFail("expected failed, got \(String(describing: manager.states[command.id]))")
        }
    }

    func testRealChainThroughManagerSucceeds() async throws {
        let manager = ProcessManager()
        let c0 = Command(id: UUID(), name: "a", command: "echo a")
        let c1 = Command(id: UUID(), name: "b", command: "echo b")
        let chain = Chain(id: UUID(), name: "seq", commandIDs: [c0.id, c1.id], stopOnError: true)

        manager.run(chain, commands: [c0.id: c0, c1.id: c1])
        try await waitReal { manager.chainStates[chain.id] == .succeeded }

        XCTAssertEqual(manager.chainStates[chain.id], .succeeded)
        XCTAssertEqual(manager.states[c0.id], .succeeded)
        XCTAssertEqual(manager.states[c1.id], .succeeded)
    }

    func testRealDaemonThroughManagerReachesDaemonRunningThenStops() async throws {
        let manager = ProcessManager()
        let command = Command(id: UUID(), name: "d", command: "echo up; sleep 30", isDaemon: true)

        manager.run(command)
        try await waitReal { manager.states[command.id] == .daemonRunning }
        XCTAssertEqual(manager.states[command.id], .daemonRunning)
        XCTAssertTrue(manager.hasLiveDaemons())

        manager.stop(command.id)
        try await waitReal { manager.states[command.id] == .idle }
        XCTAssertEqual(manager.states[command.id], .idle, "user-initiated daemon stop — neutral state, not shown as failed")
        XCTAssertFalse(manager.hasLiveDaemons())
    }
}
