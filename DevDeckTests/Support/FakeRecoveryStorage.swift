import Foundation
@testable import DevDeck

/// In-memory recovery file — the journal is tested without touching Application Support.
final class FakeRecoveryStorage: RecoveryStoring {
    var data: Data?
    private(set) var writes = 0
    func read() -> Data? { data }
    func write(_ data: Data) { self.data = data; writes += 1 }
}

/// In-memory operation markers: what the previous process left, and what this one writes.
final class FakeRecoveryMarkerStorage: RecoveryMarkerStoring {
    var stored: UInt8 = 0
    private(set) var writes: [UInt8] = []
    func readAndReset() -> UInt8 { defer { stored = 0 }; return stored }
    func write(_ mask: UInt8) { stored = mask; writes.append(mask) }
}
