import Foundation

/// "Primary run + auto-fallback" wrapper: used by the sudo path — first tries
/// `sudo` with Touch ID (pam_tid), and if authorization fails (fingerprint cancelled,
/// clamshell with no sensor) — reruns via an osascript password dialog.
///
/// Externally preserves the `RunningProcess` invariant: exactly one `.started` →
/// 0..n `.line` → exactly one terminal event. The auth-failure terminal is swallowed
/// (replaced by the fallback terminal); the fallback `.started` is suppressed if one
/// was already emitted. After a user-initiated `stop()` the fallback is NOT launched
/// (must not show a dialog after an explicit stop).
final class FallbackProcess: RunningProcess, @unchecked Sendable {
    let token = UUID()
    let output: AsyncStream<RunnerOutput>

    private let continuation: AsyncStream<RunnerOutput>.Continuation
    private let lock = NSLock()
    private var current: (any RunningProcess)?
    private var stopRequested = false
    private var driver: Task<Void, Never>?

    /// How many trailing stderr lines to retain for auth-failure detection.
    private static let stderrTailLimit = 8

    init(
        primary: @escaping @Sendable () -> any RunningProcess,
        fallback: @escaping @Sendable () -> any RunningProcess,
        shouldFallback: @escaping @Sendable (_ exitCode: Int32, _ sawStdout: Bool, _ stderrTail: [String]) -> Bool
    ) {
        (output, continuation) = AsyncStream.makeStream(
            of: RunnerOutput.self, bufferingPolicy: .unbounded
        )
        // The task ↔ self retain cycle resolves itself: both streams are finite, the task completes.
        driver = Task { [self] in
            await drive(primary: primary, fallback: fallback, shouldFallback: shouldFallback)
        }
    }

    func stop() {
        lock.lock()
        stopRequested = true
        let handle = current
        lock.unlock()
        handle?.stop()
    }

    // MARK: driver

    private func drive(
        primary: @Sendable () -> any RunningProcess,
        fallback: @Sendable () -> any RunningProcess,
        shouldFallback: @Sendable (Int32, Bool, [String]) -> Bool
    ) async {
        let first = primary()
        setCurrent(first)

        var emittedStarted = false
        var sawStdout = false
        var stderrTail: [String] = []
        var fellBack = false

        for await event in first.output {
            switch event {
            case .started:
                if !emittedStarted {
                    emittedStarted = true
                    continuation.yield(event)
                }
            case .line(let text, let stream):
                if stream == .stdout {
                    sawStdout = true
                } else {
                    stderrTail.append(text)
                    if stderrTail.count > Self.stderrTailLimit { stderrTail.removeFirst() }
                }
                continuation.yield(event)
            case .terminated(let code):
                if !isStopRequested(), shouldFallback(code, sawStdout, stderrTail) {
                    fellBack = true   // terminal swallowed — the fallback terminal will replace it
                } else {
                    continuation.yield(event)
                }
            case .cancelled:
                continuation.yield(event)
            }
        }

        if fellBack {
            let second = fallback()
            setCurrent(second)
            if isStopRequested() { second.stop() }   // stop arrived between the two runs
            for await event in second.output {
                if case .started = event, emittedStarted { continue }
                if case .started = event { emittedStarted = true }
                continuation.yield(event)
            }
        }
        continuation.finish()
    }

    private func setCurrent(_ handle: any RunningProcess) {
        lock.lock()
        current = handle
        lock.unlock()
    }

    private func isStopRequested() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }
}
