import Foundation
@testable import DevDeck

/// Returns the scripted battery state; counts reads.
final class FakeBatteryProbe: BatteryProbing, @unchecked Sendable {
    var current: BatteryState?
    private(set) var readCount = 0
    init(_ current: BatteryState? = nil) { self.current = current }
    func state() -> BatteryState? { readCount += 1; return current }
}
