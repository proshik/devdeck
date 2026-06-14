import Foundation

/// Stage 2 seam: abstraction for launching a command.
///
/// `ProcessManager` depends ONLY on this protocol — unit tests exercise
/// the state machine and chains using `FakeCommandRunner` without real processes.
///
/// `start` contract: SYNCHRONOUS, non-async, does NOT throw. Any launch failure
/// (missing binary, invalid cwd, EAGAIN) arrives as `.terminated(exitCode:)`
/// in the stream rather than as a throw — so the state machine has ONE completion path.
protocol CommandRunner: Sendable {
    func start(_ command: Command) -> any RunningProcess
}

/// Live handle for a single run. Reference type: identity == one run.
///
/// `output` stream invariant: exactly one `.started` → 0..n `.line` →
/// exactly one `.terminated` → `finish()`. `stop()` is idempotent and fire-and-forget;
/// its effect is visible only as a subsequent `.terminated` (single source of truth).
protocol RunningProcess: AnyObject, Sendable {
    /// Fresh token for every `start` — distinguishes runs of the same Command.id
    /// and lets stale events from a superseded run be ignored.
    var token: UUID { get }
    /// Single-consumer finite stream. Completed via `finish()` after `.terminated`.
    var output: AsyncStream<RunnerOutput> { get }
    /// SIGTERM → (after grace period) SIGKILL for zsh runs; best-effort for sudo.
    func stop()
}
