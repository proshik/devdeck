import XCTest
@testable import DevDeck

@MainActor
final class DeckMonitoringModelTests: XCTestCase {
    func testPanelAndWindowShareAnInFlightProbeAndCanReopenWithoutOverlap() async {
        let started = expectation(description: "probe started")
        var release: CheckedContinuation<Void, Never>?
        var probes = 0
        let monitoring = DeckMonitoringModel(interval: .milliseconds(10), refresh: {
            probes += 1
            if probes == 1 {
                await withCheckedContinuation { continuation in
                    release = continuation
                    started.fulfill()
                }
            }
        }, refreshHeavy: {})
        let panel = UUID(), window = UUID(), reopenedPanel = UUID()
        monitoring.begin(panel)
        monitoring.begin(window)
        await fulfillment(of: [started], timeout: 1)
        monitoring.end(panel)
        monitoring.end(window)
        monitoring.begin(reopenedPanel)
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(probes, 1, "reopening must not compete with the unfinished probe")
        release?.resume()
        try? await Task.sleep(for: .milliseconds(40))
        XCTAssertGreaterThan(probes, 1, "the reopened view keeps receiving measurements")
        monitoring.end(reopenedPanel)
        try? await Task.sleep(for: .milliseconds(30))
        let stoppedCount = probes
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(probes, stoppedCount, "closing the last view stops collection")
    }
}
