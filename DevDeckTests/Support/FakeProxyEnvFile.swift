import Foundation
@testable import DevDeck

/// Records what would have been written to `~/.config/devdeck/proxy.env` — the real path is never
/// touched by tests. `writeSucceeds` / `removeSucceeds` simulate a disk that refuses (full disk,
/// read-only home): the manager must then keep believing the old state and retry.
final class FakeProxyEnvFile: ProxyEnvFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _contents: String?
    private var _removeCount = 0
    private var _writeCount = 0
    private var _writeSucceeds = true
    private var _removeSucceeds = true

    /// Last written contents; nil when the file has been removed (or never written).
    var contents: String? { lock.lock(); defer { lock.unlock() }; return _contents }
    /// Attempts, successful or not — so a test can see a failed operation being retried.
    var removeCount: Int { lock.lock(); defer { lock.unlock() }; return _removeCount }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return _writeCount }

    var writeSucceeds: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _writeSucceeds }
        set { lock.lock(); defer { lock.unlock() }; _writeSucceeds = newValue }
    }

    var removeSucceeds: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _removeSucceeds }
        set { lock.lock(); defer { lock.unlock() }; _removeSucceeds = newValue }
    }

    func write(_ contents: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        _writeCount += 1
        guard _writeSucceeds else { return false }
        _contents = contents
        return true
    }

    func remove() -> Bool {
        lock.lock(); defer { lock.unlock() }
        _removeCount += 1
        guard _removeSucceeds else { return false }
        _contents = nil
        return true
    }
}
