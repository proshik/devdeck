import XCTest
@testable import DevDeck

struct StaticNetworkRouteProbe: NetworkRouteProbing {
    var value = NetworkRoutes()
    func sample() -> NetworkRoutes { value }
}

@MainActor final class NetworkMonitoringReviewTests: XCTestCase {
    private func sample(_ id: String, _ bytes: UInt64) -> NetworkInterfaceSample {
        .init(id: id, name: id == "en0" ? "Wi-Fi (en0)" : id, received: bytes, sent: bytes)
    }
    func testAutomaticUsesActiveRouteNotInactiveFirstAndSwitchesSession() {
        let model = NetworkMonitoringModel(probe: CountingProbe(), routes: StaticNetworkRouteProbe())
        model.configure(enabled: false, interface: nil, interval: 2, historyEnabled: true)
        model.accept([sample("anpi0", 0), sample("en0", 1000)], routes: .init(ipv4: "en0"), uptime: 1, date: .now, historyEnabled: true)
        XCTAssertEqual(model.source?.name, "Wi-Fi (en0)")
        XCTAssertNil(model.point)
        model.accept([sample("anpi0", 0), sample("en0", 1500)], routes: .init(ipv4: "en0"), uptime: 2, date: .now, historyEnabled: true)
        XCTAssertEqual(model.totals.received, 500)
        XCTAssertEqual(model.point?.received, 500)
        model.accept([sample("anpi0", 0), sample("en0", 1700), sample("en3", 9000)], routes: .init(ipv4: "en3"), uptime: 3, date: .now, historyEnabled: true)
        XCTAssertEqual(model.source?.id, "en3")
        XCTAssertNil(model.point); XCTAssertTrue(model.history.isEmpty); XCTAssertEqual(model.totals.received, 0)
        model.accept([sample("en3", 9200)], routes: .init(ipv4: "en3"), uptime: 4, date: .now, historyEnabled: true)
        XCTAssertEqual(model.totals.received, 200)
    }
    func testIPv6OnlyRouteAndMissingRouteOrExplicitInterfaceStayTruthful() {
        let model = NetworkMonitoringModel(probe: CountingProbe(), routes: StaticNetworkRouteProbe())
        model.configure(enabled: false, interface: nil, interval: 2, historyEnabled: true)
        model.accept([sample("anpi0", 0), sample("en6", 1000)], routes: .init(ipv6: "en6"), uptime: 1, date: .now, historyEnabled: true)
        XCTAssertEqual(model.source?.id, "en6")
        model.accept([sample("anpi0", 0), sample("en6", 1200)], routes: .init(), uptime: 2, date: .now, historyEnabled: true)
        XCTAssertNil(model.source); XCTAssertNil(model.point); XCTAssertNil(model.measuredAt)
        model.configure(enabled: false, interface: "missing", interval: 2, historyEnabled: true)
        model.accept([sample("en6", 1400)], routes: .init(ipv6: "en6"), uptime: 3, date: .now, historyEnabled: true)
        XCTAssertNil(model.source); XCTAssertNil(model.point); XCTAssertNil(model.measuredAt)
    }
    func testSecondReaderAndSameConfigurationPreserveBaselineAndEveryByte() async {
        let baseline = expectation(description: "baseline 1000 accepted, sampler waiting")
        let delta = expectation(description: "next delta accepted")
        let gate = IntervalGate(first: baseline, second: delta)
        let probe = TimedProbe()
        let model = NetworkMonitoringModel(probe: probe, routes: StaticNetworkRouteProbe(),
            uptime: { probe.uptime }, waitForNext: { _ in await gate.wait() })
        let first = UUID(), second = UUID()
        defer { model.stop(); gate.releaseAll() }
        model.configure(enabled: true, interface: "en0", interval: 2, historyEnabled: true)
        model.begin(first)
        await fulfillment(of: [baseline], timeout: 2)
        probe.advance(bytes: 1500, uptime: 12)
        model.begin(second)
        model.configure(enabled: true, interface: "en0", interval: 2, historyEnabled: true)
        model.end(first)
        gate.releaseFirst()
        await fulfillment(of: [delta], timeout: 2)
        XCTAssertEqual(model.totals.received, 500)
        XCTAssertEqual(model.point?.received, 250)
        XCTAssertEqual(model.history.count, 1)
        XCTAssertTrue(model.collecting)
        model.end(second)
    }
    func testHeldDetachedProbeKeepsSlotAndLatestConfigurationResumesAfterCleanup() async {
        let first = expectation(description: "first held probe")
        let fresh = expectation(description: "latest configuration probe")
        let overlap = expectation(description: "no probe overlaps held first"); overlap.isInverted = true
        let probe = HeldProbe(first: first, fresh: fresh, overlap: overlap)
        let model = NetworkMonitoringModel(probe: probe, routes: StaticNetworkRouteProbe())
        let panel = UUID(), page = UUID(), reopened = UUID()
        model.begin(panel)
        model.configure(enabled: true, interface: "en0", interval: 60, historyEnabled: true)
        await fulfillment(of: [first], timeout: 2)
        model.configure(enabled: true, interface: "en1", interval: 60, historyEnabled: true)
        model.end(panel); model.begin(page); model.begin(reopened)
        model.configure(enabled: true, interface: "en2", interval: 60, historyEnabled: true)
        await fulfillment(of: [overlap], timeout: 0.1)
        XCTAssertEqual(probe.maximumActive, 1)
        XCTAssertNil(model.measuredAt)
        probe.releaseFirst()
        await fulfillment(of: [fresh], timeout: 2)
        // First result is now back, but publication was invalidated before cleanup.
        XCTAssertNil(model.measuredAt); XCTAssertTrue(model.history.isEmpty)
        probe.releaseAll()
        for _ in 0..<100 where model.source == nil { await Task.yield() }
        XCTAssertEqual(model.source?.id, "en2", "latest desired config, not en0/en1, must resume")
        XCTAssertEqual(probe.maximumActive, 1)
        model.end(page); model.end(reopened); model.stop()
    }
    func testPersistentOwnerClearsHiddenHistoryOnOffOnWithoutStartingProbe() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommandStore(configURL: directory.appendingPathComponent("config.json"))
        try store.save(.empty)
        store.updateMonitoring { $0.networkInterface = "en0" }
        let probe = CountingProbe()
        let network = NetworkMonitoringModel(probe: probe, routes: StaticNetworkRouteProbe())
        let owner = DeckMonitoringModel(network: network)
        let manager = ProcessManager(runner: FakeCommandRunner())
        let engine = EngineModel(candidates: [])
        owner.start(store: store, engine: engine, manager: manager)
        defer { withExtendedLifetime(engine) {} }
        defer { owner.stop() }
        network.accept([sample("en0", 1000)], uptime: 1, date: .now, historyEnabled: true)
        network.accept([sample("en0", 1500)], uptime: 2, date: .now, historyEnabled: true)
        XCTAssertEqual(network.history.count, 1)
        store.updateMonitoring { $0.historyEnabled = false }
        for _ in 0..<100 where !network.history.isEmpty { await Task.yield() }
        XCTAssertTrue(network.history.isEmpty, "owner must observe off while network views are absent")
        store.updateMonitoring { $0.historyEnabled = true }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(network.history.isEmpty)
        XCTAssertEqual(probe.calls, 0, "observing settings must not manufacture a hidden reader")
        XCTAssertFalse(network.collecting)
    }

    @MainActor private final class IntervalGate {
        let first: XCTestExpectation, second: XCTestExpectation
        private var waits = 0
        private var pending: [CheckedContinuation<Void, Never>] = []
        init(first: XCTestExpectation, second: XCTestExpectation) { self.first = first; self.second = second }
        func wait() async {
            await withCheckedContinuation { continuation in
                pending.append(continuation); waits += 1
                if waits == 1 { first.fulfill() }
                if waits == 2 { second.fulfill() }
            }
        }
        func releaseFirst() { if !pending.isEmpty { pending.removeFirst().resume() } }
        func releaseAll() { let values = pending; pending.removeAll(); values.forEach { $0.resume() } }
    }
    private final class TimedProbe: NetworkInterfaceProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var bytes: UInt64 = 1000
        private var time: TimeInterval = 10
        var uptime: TimeInterval { lock.lock(); defer { lock.unlock() }; return time }
        func advance(bytes: UInt64, uptime: TimeInterval) { lock.lock(); self.bytes = bytes; time = uptime; lock.unlock() }
        func sample() -> [NetworkInterfaceSample]? {
            lock.lock(); defer { lock.unlock() }
            return [.init(id: "en0", name: "Wi-Fi", received: bytes, sent: bytes)]
        }
    }
    private final class CountingProbe: NetworkInterfaceProbing, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
        func sample() -> [NetworkInterfaceSample]? { lock.lock(); defer { lock.unlock() }; count += 1; return [] }
    }
    private final class HeldProbe: NetworkInterfaceProbing, @unchecked Sendable {
        private let condition = NSCondition()
        private let first: XCTestExpectation, fresh: XCTestExpectation, overlap: XCTestExpectation
        private var firstReleased = false, allReleased = false
        private var calls = 0, active = 0, maximum = 0
        init(first: XCTestExpectation, fresh: XCTestExpectation, overlap: XCTestExpectation) { self.first = first; self.fresh = fresh; self.overlap = overlap }
        var maximumActive: Int { condition.lock(); defer { condition.unlock() }; return maximum }
        func releaseFirst() { condition.lock(); firstReleased = true; condition.broadcast(); condition.unlock() }
        func releaseAll() { condition.lock(); allReleased = true; firstReleased = true; condition.broadcast(); condition.unlock() }
        func sample() -> [NetworkInterfaceSample]? {
            condition.lock(); let index = calls; calls += 1; active += 1; maximum = max(maximum, active)
            if index == 0 { first.fulfill() }
            else { if !firstReleased { overlap.fulfill() }; if index == 1 { fresh.fulfill() } }
            while !(index == 0 ? firstReleased : allReleased) { condition.wait() }
            active -= 1; condition.unlock()
            return [.init(id: index == 0 ? "en0" : "en2", name: "held", received: 1000, sent: 1000)]
        }
    }
}
