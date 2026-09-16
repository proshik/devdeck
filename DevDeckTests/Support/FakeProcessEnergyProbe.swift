import Foundation
@testable import DevDeck

/// Returns the scripted process list; counts snapshots.
final class FakeProcessEnergyProbe: ProcessEnergyProbing, @unchecked Sendable {
    var processes: [ProcessEnergy]
    private(set) var snapshotCount = 0
    init(_ processes: [ProcessEnergy] = []) { self.processes = processes }
    func snapshot() -> [ProcessEnergy] { snapshotCount += 1; return processes }
}
