import Foundation
@testable import DevDeck

/// Programmable probe: returns pre-configured samples in order (the last one repeats).
final class FakeVMMemoryProbe: VMMemoryProbing, @unchecked Sendable {
    private var samples: [VMMemoryInfo?]
    private(set) var calls = 0
    init(_ samples: [VMMemoryInfo?]) { self.samples = samples }
    func sample() -> VMMemoryInfo? {
        defer { calls += 1 }
        guard !samples.isEmpty else { return nil }
        return calls < samples.count ? samples[calls] : samples.last!
    }
}
