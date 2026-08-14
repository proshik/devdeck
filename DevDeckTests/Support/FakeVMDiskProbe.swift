import Foundation
@testable import DevDeck

/// Returns the scripted disk info; counts samples.
final class FakeVMDiskProbe: VMDiskProbing, @unchecked Sendable {
    var info: VMDiskInfo?
    private(set) var sampleCount = 0
    init(_ info: VMDiskInfo? = nil) { self.info = info }
    func sample() -> VMDiskInfo? { sampleCount += 1; return info }
}
