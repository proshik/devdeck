import Foundation
@testable import DevDeck

/// Push-based discovery fake: the test calls `emit` to publish a result set, exactly like a
/// Bonjour browse update — no mDNS, no network, no timing.
final class FakeProxyDiscovering: ProxyDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: AsyncStream<[DiscoveredProxy]>.Continuation?
    private var _stopCount = 0
    private var _resultsCallCount = 0

    var stopCount: Int { lock.lock(); defer { lock.unlock() }; return _stopCount }
    /// How many times a browse stream was requested — asserts discovery stays idle when disabled.
    var resultsCallCount: Int { lock.lock(); defer { lock.unlock() }; return _resultsCallCount }

    func results() -> AsyncStream<[DiscoveredProxy]> {
        let (stream, continuation) = AsyncStream.makeStream(of: [DiscoveredProxy].self,
                                                            bufferingPolicy: .unbounded)
        lock.lock()
        _resultsCallCount += 1
        self.continuation = continuation
        lock.unlock()
        return stream
    }

    /// Publish a full result set (Bonjour always reports the complete current set).
    func emit(_ proxies: [DiscoveredProxy]) {
        lock.lock()
        let continuation = self.continuation
        lock.unlock()
        continuation?.yield(proxies)
    }

    func stop() {
        lock.lock()
        _stopCount += 1
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.finish()
    }
}
