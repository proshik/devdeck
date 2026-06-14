import Foundation
@testable import DevDeck

/// Programmable minikube probe: returns samples in order (the last one repeats).
final class FakeMinikubeProbe: MinikubeProbing, @unchecked Sendable {
    private var samples: [MinikubeSample?]
    private(set) var calls = 0
    init(_ samples: [MinikubeSample?]) { self.samples = samples }
    func sample() -> MinikubeSample? {
        defer { calls += 1 }
        guard !samples.isEmpty else { return nil }
        return calls < samples.count ? samples[calls] : samples.last!
    }
}

/// Programmable OOM inspector. Thread-safe call counter: scan is called from a detached task.
final class FakeOOMInspector: OOMInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var report: OOMReport
    private var scans = 0
    init(report: OOMReport = OOMReport(events: [], dmesgLines: [])) { self.report = report }
    var calls: Int { lock.withLock { scans } }
    func scan() -> OOMReport { lock.withLock { scans += 1; return report } }
}
