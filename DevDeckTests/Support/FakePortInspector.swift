import Foundation
@testable import DevDeck

/// Programmable port table — no real lsof. Thread-safe: `occupant(ofPort:)` is called
/// from a detached task while tests mutate `occupants` on the main actor.
final class FakePortInspector: PortInspector, @unchecked Sendable {
    private let lock = NSLock()
    private var _occupants: [Int: PortOccupant] = [:]
    private var _queriedPorts: [Int] = []

    var occupants: [Int: PortOccupant] {
        get { lock.lock(); defer { lock.unlock() }; return _occupants }
        set { lock.lock(); defer { lock.unlock() }; _occupants = newValue }
    }
    /// Query log — asserts that the pre-check actually ran.
    var queriedPorts: [Int] { lock.lock(); defer { lock.unlock() }; return _queriedPorts }

    func occupant(ofPort port: Int) -> PortOccupant? {
        lock.lock(); defer { lock.unlock() }
        _queriedPorts.append(port)
        return _occupants[port]
    }
}
