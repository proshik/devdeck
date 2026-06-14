import Foundation

/// The complete event vocabulary for a single command run.
///
/// `Equatable` — the fake runner scripts exact sequences, tests compare them directly.
/// `Sendable` — values cross the actor boundary cleanly (Process I/O happens off main,
/// state is mutated on main).
///
/// Stream invariant: exactly one `.started` → 0..n `.line` → exactly one
/// `.terminated` → `finish()`. `.terminated` always arrives (including on launch failure).
enum RunnerOutput: Sendable, Equatable {
    /// `pid == nil` for the sudo path (no managed child process).
    case started(pid: Int32?)
    /// A single logical line (no `\n`, trailing `\r` stripped), tagged with its stream.
    case line(String, stream: OutputChannel)
    /// Signal death → 128+signal (SIGTERM → 143, SIGKILL → 137).
    /// Launch failure → 127. Clean exit → the process's own exit code.
    case terminated(exitCode: Int32)
    /// Recognized user cancellation (sudo password dialog dismissed).
    /// Terminal event for the run: the chain treats it as a stop, not a step failure.
    case cancelled
}

/// Output stream channel. Named `OutputChannel` (not `OutputStream`) to avoid
/// colliding with `Foundation.OutputStream`.
enum OutputChannel: Sendable, Equatable {
    case stdout
    case stderr
}

/// A single log line stored in the ring buffer.
struct LogLine: Sendable, Equatable {
    let text: String
    let stream: OutputChannel
}
