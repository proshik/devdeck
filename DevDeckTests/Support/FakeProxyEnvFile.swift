import Foundation
@testable import DevDeck

/// Records what would have been written to `~/.config/devdeck/proxy.env` — the real path is never
/// touched by tests.
final class FakeProxyEnvFile: ProxyEnvFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _contents: String?
    private var _removeCount = 0
    private var _writeCount = 0

    /// Last written contents; nil when the file has been removed (or never written).
    var contents: String? { lock.lock(); defer { lock.unlock() }; return _contents }
    var removeCount: Int { lock.lock(); defer { lock.unlock() }; return _removeCount }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return _writeCount }

    func write(_ contents: String) {
        lock.lock(); defer { lock.unlock() }
        _contents = contents
        _writeCount += 1
    }

    func remove() {
        lock.lock(); defer { lock.unlock() }
        _contents = nil
        _removeCount += 1
    }
}
