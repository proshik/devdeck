import Foundation
@testable import DevDeck

/// Scriptable runner WITHOUT real processes, sleeps, or timing.
///
/// Two modes per run:
/// - **eager**: set `eagerScripts[command.id]` → the entire sequence is emitted
///   immediately on `start` (and `finish` is called if the last event is `.terminated`);
/// - **manual**: no script → the test pushes events through `controller(for:)`,
///   verifying intermediate states and the STRICT ordering of chain steps.
final class FakeCommandRunner: CommandRunner, @unchecked Sendable {

    /// Controller for a single run — driven by the test.
    final class Controller: @unchecked Sendable {
        let command: Command
        let token = UUID()
        private let continuation: AsyncStream<RunnerOutput>.Continuation
        private(set) var stopCount = 0

        init(command: Command, _ continuation: AsyncStream<RunnerOutput>.Continuation) {
            self.command = command
            self.continuation = continuation
        }

        func started(pid: Int32? = 1) { continuation.yield(.started(pid: pid)) }
        func line(_ text: String, _ stream: OutputChannel = .stdout) {
            continuation.yield(.line(text, stream: stream))
        }
        func terminate(_ code: Int32) {
            continuation.yield(.terminated(exitCode: code))
            continuation.finish()
        }
        /// User cancellation (simulates cancelling a sudo dialog).
        func cancel() {
            continuation.yield(.cancelled)
            continuation.finish()
        }
        func recordStop() { stopCount += 1 }
    }

    private let lock = NSLock()
    /// Script keyed by Command.id: an eager sequence OR absent → manual mode.
    var eagerScripts: [UUID: [RunnerOutput]] = [:]
    /// Behavior of `stop()`: by default auto-`terminate(143)` (like death by SIGTERM).
    var autoTerminateOnStopCode: Int32? = 143

    private var _startedCommandIDs: [UUID] = []
    private var _controllers: [UUID: Controller] = [:]

    /// Order of starts — for asserting the sequence of chain steps.
    var startedCommandIDs: [UUID] { lock.lock(); defer { lock.unlock() }; return _startedCommandIDs }
    func controller(for id: UUID) -> Controller? {
        lock.lock(); defer { lock.unlock() }; return _controllers[id]
    }

    func start(_ command: Command) -> any RunningProcess {
        lock.lock()
        _startedCommandIDs.append(command.id)
        let script = eagerScripts[command.id]
        let (stream, continuation) = AsyncStream.makeStream(
            of: RunnerOutput.self, bufferingPolicy: .unbounded
        )
        let controller = Controller(command: command, continuation)
        _controllers[command.id] = controller
        let handle = FakeRunningProcess(controller: controller,
                                        stream: stream,
                                        autoStopCode: autoTerminateOnStopCode)
        lock.unlock()

        if let script {
            for event in script { continuation.yield(event) }
            if case .terminated = script.last { continuation.finish() }
        }
        return handle
    }
}

final class FakeRunningProcess: RunningProcess, @unchecked Sendable {
    let token: UUID
    let output: AsyncStream<RunnerOutput>
    private let controller: FakeCommandRunner.Controller
    private let autoStopCode: Int32?

    init(controller: FakeCommandRunner.Controller,
         stream: AsyncStream<RunnerOutput>,
         autoStopCode: Int32?) {
        self.controller = controller
        self.token = controller.token
        self.output = stream
        self.autoStopCode = autoStopCode
    }

    func stop() {
        controller.recordStop()
        if let autoStopCode { controller.terminate(autoStopCode) }
    }
}
