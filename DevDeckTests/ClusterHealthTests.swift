import XCTest
@testable import DevDeck

final class ClusterHealthTests: XCTestCase {

    // MARK: pure verdict

    func testColimaUnavailableIsUnknown() {
        XCTAssertEqual(clusterHealthVerdict(colimaRunning: nil, minikubeStatus: nil).level, .unknown)
    }

    func testColimaStoppedIsDown() {
        XCTAssertEqual(clusterHealthVerdict(colimaRunning: false, minikubeStatus: "host: Running").level, .down)
    }

    func testColimaUpMinikubeFullyRunningIsHealthy() {
        let mk = "host: Running\nkubelet: Running\napiserver: Running\nkubeconfig: Configured"
        XCTAssertEqual(clusterHealthVerdict(colimaRunning: true, minikubeStatus: mk).level, .healthy)
    }

    func testColimaUpMinikubePartialIsDegraded() {
        let mk = "host: Running\nkubelet: Stopped\napiserver: Stopped"
        XCTAssertEqual(clusterHealthVerdict(colimaRunning: true, minikubeStatus: mk).level, .degraded)
    }

    func testColimaUpMinikubeUnknownIsDegraded() {
        XCTAssertEqual(clusterHealthVerdict(colimaRunning: true, minikubeStatus: nil).level, .degraded)
    }

    // MARK: colima json parsing

    func testParseColimaRunning() {
        XCTAssertEqual(parseColimaRunning(#"{"name":"default","status":"Running","cpus":6}"#), true)
        XCTAssertEqual(parseColimaRunning(#"{"status":"Stopped"}"#), false)
        XCTAssertNil(parseColimaRunning("not json"))
    }

    // MARK: ProcessManager wiring

    @MainActor
    func testRefreshCachesWhenEnabled() async {
        let probe = FakeClusterHealthProbe(ClusterHealth(level: .healthy, detail: "ok"))
        let m = ProcessManager(runner: FakeCommandRunner(), clusterProbe: probe, clusterHealthEnabled: { true })
        await m.refreshClusterHealth()
        XCTAssertEqual(m.cachedClusterHealth?.level, .healthy)
    }

    @MainActor
    func testRefreshIsNilWhenDisabled() async {
        let probe = FakeClusterHealthProbe(ClusterHealth(level: .healthy, detail: "ok"))
        let m = ProcessManager(runner: FakeCommandRunner(), clusterProbe: probe, clusterHealthEnabled: { false })
        await m.refreshClusterHealth()
        XCTAssertNil(m.cachedClusterHealth)
    }
}
