import Foundation
@testable import DevDeck

/// Scripted reverse naming — no mDNS, no waiting. An IP absent from `names` resolves to nothing,
/// which is how a real unnamed peer behaves.
final class FakeProxyClientNaming: ProxyClientNaming, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String]
    private var _calls: [String] = []

    init(names: [String: String] = [:]) {
        self.names = names
    }

    /// Every IP this resolver was asked about, in order — asserts the retry policy.
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    func hostname(for ip: String) async -> String? {
        lock.lock(); defer { lock.unlock() }
        _calls.append(ip)
        return names[ip]
    }
}
