import Foundation
@testable import DevDeck

/// Scripted reverse naming — no mDNS, no waiting. An IP absent from `names` resolves to nothing,
/// which is how a real unnamed peer behaves.
final class FakeProxyClientNaming: ProxyClientNaming, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String]
    private var _calls: [String] = []
    /// When true, the NEXT call to `hostname(for:)` suspends instead of answering right away — lets
    /// a test hold one lookup "in flight" (e.g. across a `clear()`) with no real-time wait. The flag
    /// is consumed by that one call; every call before or after it answers immediately as usual.
    private var holdNext = false
    private var pendingContinuation: CheckedContinuation<String?, Never>?

    init(names: [String: String] = [:]) {
        self.names = names
    }

    /// Every IP this resolver was asked about, in order — asserts the retry policy.
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    /// The lock is taken here, in a plain synchronous method, and never across an `await` — taking
    /// it directly inside `hostname(for:)` (an `async` function) is unavailable under Swift 6's
    /// strict concurrency checking.
    private func recordCall(_ ip: String) -> (answer: String?, hold: Bool) {
        lock.lock()
        defer { lock.unlock() }
        _calls.append(ip)
        let hold = holdNext
        holdNext = false
        return (names[ip], hold)
    }

    /// Arm the hold for the next call to `hostname(for:)`.
    func holdNextAnswer() {
        lock.lock(); holdNext = true; lock.unlock()
    }

    /// Resume the held call with the given answer. No-op if nothing is currently held.
    func releaseHeldAnswer(_ name: String?) {
        lock.lock()
        let continuation = pendingContinuation
        pendingContinuation = nil
        lock.unlock()
        continuation?.resume(returning: name)
    }

    func hostname(for ip: String) async -> String? {
        let (answer, hold) = recordCall(ip)
        guard hold else { return answer }
        return await withCheckedContinuation { continuation in
            lock.lock()
            pendingContinuation = continuation
            lock.unlock()
        }
    }
}
