import XCTest
@testable import DevDeck

/// Host-side view of who is using the share. Every window is driven by an injected clock and the
/// publish/sweep steps are invoked directly, so the suite has no sleeps and no timing flake.
@MainActor
final class ProxyClientMonitorTests: XCTestCase {

    /// Mutable clock — `ProxyClientMonitor` reads the time through a closure.
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private var clock: TestClock!
    private var naming: FakeProxyClientNaming!

    override func setUp() {
        super.setUp()
        clock = TestClock()
        naming = FakeProxyClientNaming(names: ["192.168.31.42": "macbook-vasya"])
    }

    /// Sweep and publish intervals are pushed out of the way — the tests call `sweepNow()` and
    /// `publishNow()` themselves.
    private func makeMonitor() -> ProxyClientMonitor {
        let clock = clock!
        return ProxyClientMonitor(naming: naming,
                                  now: { clock.now },
                                  publishInterval: .seconds(3600),
                                  sweepInterval: .seconds(3600))
    }

    private func openLine(_ client: String, sid: String) -> String {
        """
        {"client":"\(client)","kind":"handler","level":"info","local":"192.168.31.5:9999",\
        "msg":"\(client) <> 192.168.31.5:9999","service":"devdeck-proxy","sid":"\(sid)"}
        """
    }

    private func closeLine(_ client: String, sid: String) -> String {
        """
        {"client":"\(client)","kind":"handler","level":"info","local":"192.168.31.5:9999",\
        "msg":"\(client) >< 192.168.31.5:9999","service":"devdeck-proxy","sid":"\(sid)"}
        """
    }

    func testTwoSessionsFromOneMachineAreOneClient() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.ingest(openLine("192.168.31.42:1001", sid: "b"))
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.count, 1)
        XCTAssertEqual(monitor.clients.first?.ip, "192.168.31.42")
        XCTAssertEqual(monitor.clients.first?.liveSessions, 2)
        XCTAssertEqual(monitor.activeCount, 1)
    }

    func testClosingOneSessionLeavesTheOther() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.ingest(openLine("192.168.31.42:1001", sid: "b"))
        monitor.ingest(closeLine("192.168.31.42:1000", sid: "a"))
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.first?.liveSessions, 1)
    }

    func testTwoMachinesAreTwoClients() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.ingest(openLine("192.168.31.77:2000", sid: "b"))
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.count, 2)
        XCTAssertEqual(monitor.activeCount, 2)
    }

    func testAnIdleMachineStaysActiveInsideTheWindow() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.ingest(closeLine("192.168.31.42:1000", sid: "a"))

        clock.advance(60)   // inside the 120 s active window
        monitor.publishNow()
        XCTAssertEqual(monitor.clients.first?.liveSessions, 0)
        XCTAssertTrue(monitor.clients.first?.isActive == true,
                      "proxy sessions are short — a quiet minute is not a disconnect")
        XCTAssertEqual(monitor.activeCount, 1)

        clock.advance(120)  // now past it
        monitor.publishNow()
        XCTAssertFalse(monitor.clients.first?.isActive == true)
        XCTAssertEqual(monitor.activeCount, 0)
        XCTAssertEqual(monitor.clients.count, 1, "still listed, just no longer active")
    }

    func testAnIdleMachineIsSweptAfterTheRetentionWindow() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.ingest(closeLine("192.168.31.42:1000", sid: "a"))

        clock.advance(599)
        monitor.sweepNow()
        XCTAssertEqual(monitor.clients.count, 1)

        clock.advance(2)
        monitor.sweepNow()
        XCTAssertTrue(monitor.clients.isEmpty)
    }

    func testAMachineWithLiveSessionsIsNeverSwept() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))

        clock.advance(3600)
        monitor.sweepNow()
        XCTAssertEqual(monitor.clients.count, 1)
    }

    func testListenerRestartDropsLiveSessionsButKeepsTheMachine() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.listenerDidStart()
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.count, 1, "who was just here survives a watchdog restart")
        XCTAssertEqual(monitor.clients.first?.liveSessions, 0,
                       "the process that owned those sessions is gone")
    }

    func testSessionsFromBeforeARestartDoNotGoNegative() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.listenerDidStart()
        monitor.ingest(closeLine("192.168.31.42:1000", sid: "a"))
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.first?.liveSessions, 0)
    }

    func testClearRemovesEverything() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.clear()

        XCTAssertTrue(monitor.clients.isEmpty)
        XCTAssertEqual(monitor.activeCount, 0)
    }

    func testLoopbackIsNotAMachine() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("127.0.0.1:1000", sid: "a"))
        monitor.ingest(openLine("[::1]:1001", sid: "b"))
        monitor.publishNow()

        XCTAssertTrue(monitor.clients.isEmpty, "our own exit-IP probe is not another machine")
    }

    func testUnparsableLinesChangeNothing() {
        let monitor = makeMonitor()
        monitor.ingest("gost: something went wrong")
        monitor.ingest("")
        monitor.publishNow()

        XCTAssertTrue(monitor.clients.isEmpty)
    }

    func testAResolvedNameReachesTheClient() async {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        await sleepUntil({ self.naming.calls == ["192.168.31.42"] },
                         message: "the resolver was never asked")
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.first?.hostname, "macbook-vasya")
        XCTAssertEqual(monitor.clients.first?.displayName, "macbook-vasya")
    }

    func testAnUnresolvedMachineIsShownByItsAddress() async {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.99:1000", sid: "a"))
        await sleepUntil({ self.naming.calls == ["192.168.31.99"] },
                         message: "the resolver was never asked")
        monitor.publishNow()

        XCTAssertNil(monitor.clients.first?.hostname)
        XCTAssertEqual(monitor.clients.first?.displayName, "192.168.31.99")
    }

    func testAFailedLookupIsNotRetriedOnEveryRequest() async {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.99:1000", sid: "a"))
        await sleepUntil({ self.naming.calls.count == 1 }, message: "the resolver was never asked")

        monitor.ingest(openLine("192.168.31.99:1001", sid: "b"))
        clock.advance(60)
        monitor.ingest(openLine("192.168.31.99:1002", sid: "c"))
        XCTAssertEqual(naming.calls.count, 1, "a busy unnamed peer must not flood the resolver")

        clock.advance(300)   // past the 300 s retry delay
        monitor.ingest(openLine("192.168.31.99:1003", sid: "d"))
        await sleepUntil({ self.naming.calls.count == 2 },
                         message: "the retry after the delay never happened")
    }

    func testActiveMachinesSortAboveRetiredOnes() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.ingest(closeLine("192.168.31.42:1000", sid: "a"))
        clock.advance(300)                                    // .42 goes quiet, past the active window
        monitor.ingest(openLine("192.168.31.77:2000", sid: "b"))
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.map(\.ip), ["192.168.31.77", "192.168.31.42"])
    }
}
