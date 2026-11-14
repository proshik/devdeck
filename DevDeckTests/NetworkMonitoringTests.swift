import XCTest
import SwiftUI
import AppKit
@testable import DevDeck

final class NetworkMonitoringTests: XCTestCase {
    private func sample(_ id: String, _ input: UInt64, _ output: UInt64) -> NetworkInterfaceSample {
        .init(id: id, name: id, received: input, sent: output)
    }
    private func sample(_ input: UInt64, _ output: UInt64) -> NetworkInterfaceSample { sample("en0", input, output) }
    func testFirstDeltaResetAndWakeDoNotInventTraffic() {
        var meter = NetworkTrafficAccumulator()
        meter.select("en0")
        XCTAssertNil(meter.consume(sample(1000, 2000), uptime: 10, date: .now))
        let point = meter.consume(sample(1200, 2060), uptime: 12, date: .now)
        XCTAssertEqual(point?.received, 100); XCTAssertEqual(point?.sent, 30)
        XCTAssertEqual(meter.received, 200)
        XCTAssertNil(meter.consume(sample(10, 10), uptime: 14, date: .now))
        XCTAssertEqual(meter.received, 200)
        meter.resetInterval()
        XCTAssertNil(meter.consume(sample(50000, 50000), uptime: 1000, date: .now))
        XCTAssertEqual(meter.received, 200)
        XCTAssertNil(meter.consume(nil, uptime: 1001, date: .now))
        XCTAssertNil(meter.consume(sample(60000, 60000), uptime: 1002, date: .now))
    }
    func testInterfaceChangeStartsNewSessionAndRequiresBaseline() {
        var meter = NetworkTrafficAccumulator()
        meter.select("en0")
        _ = meter.consume(sample(100, 100), uptime: 1, date: .now)
        _ = meter.consume(sample(200, 200), uptime: 2, date: .now)
        meter.select("en1")
        XCTAssertEqual(meter.received, 0)
        XCTAssertNil(meter.consume(sample("en1", 9000, 9000), uptime: 3, date: .now))
        XCTAssertEqual(meter.consume(sample("en1", 9200, 9400), uptime: 5, date: .now)?.sent, 200)
    }
    func testQualityUnitsAndMalformedResults() throws {
        let result = try NetworkQualityResult.parse(Data(#"{"dl_throughput":8000000,"ul_throughput":4000000,"responsiveness":120,"base_rtt":12.5,"interface_name":"en0"}"#.utf8), date: .distantPast)
        XCTAssertEqual(result.download, 8_000_000); XCTAssertEqual(result.latency, 12.5)
        XCTAssertEqual(result.date, .distantPast)
        XCTAssertThrowsError(try NetworkQualityResult.parse(Data("{}".utf8), date: .now))
    }
    func testTimeoutCancellationAndNetworkFailureReapOwnedChild() {
        let timeout = Child()
        var clock = 0.0
        XCTAssertThrowsError(try LiveNetworkQualityTest.collect(timeout, cancelled: { false }, now: { clock }, wait: { clock += 1 }, timeout: 2)) { XCTAssertEqual($0 as? NetworkQualityFailure, .timeout) }
        XCTAssertTrue(timeout.reaped)
        let cancelled = Child()
        XCTAssertThrowsError(try LiveNetworkQualityTest.collect(cancelled, cancelled: { true })) { XCTAssertEqual($0 as? NetworkQualityFailure, .cancelled) }
        XCTAssertTrue(cancelled.reaped)
        let failed = Child(); failed.success = false
        XCTAssertThrowsError(try LiveNetworkQualityTest.collect(failed, cancelled: { false })) { XCTAssertEqual($0 as? NetworkQualityFailure, .network) }
        XCTAssertTrue(failed.reaped)
    }
    @MainActor func testPanelObservationNeverRunsQualityAndMissingSelectionStaysUnavailable() async throws {
        let quality = Quality()
        let model = NetworkMonitoringModel(probe: Probe(), routes: StaticNetworkRouteProbe(), quality: quality)
        let reader = UUID(); model.begin(reader)
        model.configure(enabled: true, interface: "missing", interval: 2, historyEnabled: true)
        for _ in 0..<20 { await Task.yield() }
        model.accept([sample(100, 100)], uptime: 1, date: .now, historyEnabled: true)
        model.accept([sample(200, 200)], uptime: 2, date: .now, historyEnabled: true)
        XCTAssertNil(model.point); XCTAssertNil(model.measuredAt)
        let count = await quality.count(); XCTAssertEqual(count, 0)
        model.runTest()
        for _ in 0..<100 { await Task.yield() }
        model.cancelTest()
        XCTAssertEqual(model.failure, .cancelled)
        model.end(reader)
        XCTAssertFalse(model.collecting)
    }
    @MainActor func testFailedManualTestKeepsPreviousResultAndEndsProgress() async {
        let previous = NetworkQualityResult(date: .distantPast, interface: "en0", download: 8_000_000,
                                            upload: 4_000_000, responsiveness: 120, latency: 12)
        let model = NetworkMonitoringModel(probe: Probe(), routes: StaticNetworkRouteProbe(), quality: FailingQuality())
        model.result = previous
        model.runTest()
        for _ in 0..<100 where model.runningTest { await Task.yield() }
        XCTAssertFalse(model.runningTest)
        XCTAssertEqual(model.failure, .network)
        XCTAssertEqual(model.result, previous)
        model.stop()
    }
    private struct FailingQuality: NetworkQualityTesting {
        func run(interface: String?) async throws -> NetworkQualityResult { throw NetworkQualityFailure.network }
    }

    @MainActor func testNetworkModuleFitsCompactPanelInBothLanguages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommandStore(configURL: directory.appendingPathComponent("config.json"))
        try store.save(.empty)
        let network = NetworkMonitoringModel(probe: Probe(), routes: StaticNetworkRouteProbe())
        // A populated chart must fit too: an empty chart cannot expose crowded axes.
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0...180 {
            network.accept([sample(UInt64(index) * 2_000_000, UInt64(index) * 500_000)],
                           routes: .init(ipv4: "en0"), uptime: Double(index) * 2, date: date.addingTimeInterval(Double(index) * 2), historyEnabled: true)
        }
        XCTAssertEqual(network.history.count, 180)
        let monitoring = DeckMonitoringModel(network: network)
        let oldLanguage = LocalizationManager.shared.language
        defer { LocalizationManager.shared.language = oldLanguage; network.stop() }
        for language in AppLanguage.allCases {
            LocalizationManager.shared.language = language
            let root = NetworkMetricsView(onDetails: {}).padding(16).frame(width: 380)
                .environment(store).environment(monitoring)
            let hosting = NSHostingController(rootView: root)
            let window = NSWindow(contentViewController: hosting)
            window.isReleasedWhenClosed = false
            window.setFrameOrigin(NSPoint(x: -2000, y: -2000)); window.orderFront(nil)
            try await Task.sleep(for: .milliseconds(100))
            hosting.view.layoutSubtreeIfNeeded()
            XCTAssertEqual(hosting.view.fittingSize.width, 380, accuracy: 1)
            XCTAssertLessThan(hosting.view.fittingSize.height, 500)
            let bitmap = try XCTUnwrap(hosting.view.bitmapImageRepForCachingDisplay(in: hosting.view.bounds))
            hosting.view.cacheDisplay(in: hosting.view.bounds, to: bitmap)
            let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
            attachment.name = "network-compact-\(language.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
            window.close()
        }
    }

    private final class Child: MonitoringChild {
        var reaped = false
        var success: Bool?
        func readAvailable() -> Data { Data() }
        var finishedSuccessfully: Bool? { success }
        func terminateGroupAndReap() { reaped = true }
    }
    private struct Probe: NetworkInterfaceProbing { func sample() -> [NetworkInterfaceSample]? { [] } }
    private actor Quality: NetworkQualityTesting {
        var calls = 0
        func count() -> Int { calls }
        func run(interface: String?) async throws -> NetworkQualityResult {
            calls += 1
            try await Task.sleep(for: .seconds(100))
            throw CancellationError()
        }
    }
}
