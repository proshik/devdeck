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

@MainActor final class MonitoringSnapshotTests: XCTestCase {
    private func sample(_ tick: UInt64) -> DeckMonitoringSnapshot {
        .init(mac: .init(date: Date(timeIntervalSince1970: Double(tick)), value: .init(
            sample: .init(cpu: .init(user: tick * 2, system: tick, idle: tick * 7, nice: 0)),
            cpuBusyPercent: nil, swapInBytesPerSecond: nil, swapOutBytesPerSecond: nil)))
    }

    func testHistoryIsBoundedAndUnavailableSamplesRemainMissing() async {
        let enough = expectation(description: "bounded samples")
        var tick: UInt64 = 0
        let model = DeckMonitoringModel(interval: .milliseconds(1), sample: { _ in
            tick += 1
            if tick == 190 { enough.fulfill() }
            return self.sample(tick)
        })
        let reader = UUID(); model.begin(reader)
        await fulfillment(of: [enough], timeout: 3)
        model.end(reader)
        XCTAssertEqual(model.history.count, 180)
        XCTAssertEqual(model.history.last?.cpu, 30)
        XCTAssertNil(model.history.last?.memory)
        XCTAssertNil(model.snapshot.mac?.value.sample.memory)
        model.configure(.init(settings: .init(historyEnabled: false)))
        XCTAssertTrue(model.history.isEmpty)
        XCTAssertNotNil(model.snapshot.mac, "last value stays visible when stopped")
    }

    func testDisabledOrSupersededGenerationCannotPublishOrOverlap() async {
        for change in 0...2 {
            let entered = expectation(description: "held \(change)")
            let resumed = expectation(description: "fresh \(change)")
            var release: CheckedContinuation<Void, Never>?
            var calls = 0
            let model = DeckMonitoringModel(interval: .milliseconds(5), sample: { _ in
                calls += 1
                if calls == 1 { await withCheckedContinuation { release = $0; entered.fulfill() } }
                else if calls == 2 { resumed.fulfill() }
                return self.sample(UInt64(calls))
            })
            let reader = UUID(); model.begin(reader)
            await fulfillment(of: [entered], timeout: 1)
            if change == 0 { model.configure(.init(settings: .init(enabled: false))) }
            if change == 1 { model.setSuspended(true) }
            if change == 2 { model.configure(.init(engine: .dockerDesktop)) }
            for _ in 0..<10 { await Task.yield() }
            XCTAssertEqual(calls, 1)
            release?.resume()
            if change != 2 {
                try? await Task.sleep(for: .milliseconds(20))
                XCTAssertNil(model.snapshot.mac)
                if change == 0 { model.configure(.init()) } else { model.setSuspended(false) }
            }
            await fulfillment(of: [resumed], timeout: 1)
            model.end(reader)
            XCTAssertNil(model.history.first?.cpu, "generation change resets CPU baseline")
            XCTAssertFalse(model.history.contains { $0.date == Date(timeIntervalSince1970: 1) },
                           "held result from previous generation must never enter history")
            XCTAssertGreaterThanOrEqual(model.snapshot.mac?.date.timeIntervalSince1970 ?? 0, 2,
                                        "a distinct fresh result must actually publish")
        }
    }
}

extension MonitoringSnapshotTests {
    func testHeavyCadenceSurvivesReopeningAndIntervalChange() async {
        var clock = Date(timeIntervalSince1970: 100)
        var calls = 0, heavyCalls = 0
        let model = DeckMonitoringModel(interval: .milliseconds(2), now: { clock }, sample: { heavy in
            calls += 1; if heavy { heavyCalls += 1 }; return .init()
        })
        let reader = UUID(); model.begin(reader)
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertGreaterThan(calls, 2)
        XCTAssertEqual(heavyCalls, 1)
        model.end(reader); model.begin(reader)
        model.configure(.init(settings: .init(intervalSeconds: 5)))
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(heavyCalls, 1, "reopening/interval edits must not flood heavy probes")
        clock = clock.addingTimeInterval(15)
        try? await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(heavyCalls, 2)
        model.end(reader)
    }
}
