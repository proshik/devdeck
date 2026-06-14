import Foundation
@testable import DevDeck

/// Returns scripted samples in order, repeating the last one once exhausted.
final class FakeHostMetricsProbe: HostMetricsProbing, @unchecked Sendable {
    private let samples: [HostMetricsSample]
    private var index = 0
    private(set) var lastBuildPID: Int32?

    init(_ samples: [HostMetricsSample]) { self.samples = samples }

    func sample(buildPID: Int32?) -> HostMetricsSample {
        lastBuildPID = buildPID
        defer { if index < samples.count - 1 { index += 1 } }
        return samples.isEmpty
            ? HostMetricsSample(pressure: .normal, swapInsPages: 0, swapOutsPages: 0,
                                compressorPages: 0, totalBytes: 16 * 1_073_741_824, buildFootprintBytes: 0)
            : samples[min(index, samples.count - 1)]
    }
}
