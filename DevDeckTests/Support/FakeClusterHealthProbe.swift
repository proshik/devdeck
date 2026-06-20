import Foundation
@testable import DevDeck

/// Returns a fixed cluster-health verdict — exercises ProcessManager wiring without real CLI calls.
final class FakeClusterHealthProbe: ClusterHealthProbing, @unchecked Sendable {
    private let health: ClusterHealth
    init(_ health: ClusterHealth) { self.health = health }
    func sample() -> ClusterHealth { health }
}
