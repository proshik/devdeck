import XCTest
@testable import DevDeck

/// The path from a daemon's stdout/stderr to the connected-machines list: `ProcessManager` reports
/// every line through a generic hook, `AppDelegate` points that hook at `ProxyManager`, and
/// `ProxyManager` keeps only the proxy listener's own output.
@MainActor
final class ProxyClientWiringTests: XCTestCase {

    private func openLine(_ client: String, sid: String) -> String {
        """
        {"client":"\(client)","kind":"handler","level":"info","local":"192.168.31.5:9999",\
        "msg":"\(client) <> 192.168.31.5:9999","service":"devdeck-proxy","sid":"\(sid)"}
        """
    }

    func testProcessManagerReportsEveryOutputLine() async {
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        let command = Command(name: "echo", command: "echo hi")
        runner.eagerScripts[command.id] = [
            .started(pid: 1),
            .line("hello", stream: .stdout),
            .line("trouble", stream: .stderr),
            .terminated(exitCode: 0),
        ]

        var seen: [(UUID, String, OutputChannel)] = []
        manager.outputObserver = { seen.append(($0, $1, $2)) }
        manager.run(command)

        await sleepUntil({ seen.count == 2 }, message: "the output hook never fired")
        XCTAssertEqual(seen.map(\.1), ["hello", "trouble"])
        XCTAssertEqual(seen.map(\.0), [command.id, command.id])
        XCTAssertEqual(seen.map(\.2), [.stdout, .stderr])
    }

    func testOnlyTheListenersOwnOutputCounts() {
        let monitor = ProxyClientMonitor(naming: FakeProxyClientNaming(),
                                         publishInterval: .seconds(3600),
                                         sweepInterval: .seconds(3600))
        // shareConfigFile: without this, the default resolves to the REAL
        // ~/Library/Application Support/DevDeck/gost.json — see ProxyManagerShareTests for the
        // established convention of always injecting a FakePrivateFile for it.
        let proxy = ProxyManager(discovering: FakeProxyDiscovering(),
                                 advertiser: FakeProxyAdvertising(),
                                 credentials: FakeProxyCredentialStore(),
                                 shareConfigFile: FakePrivateFile(),
                                 clientMonitor: monitor)

        proxy.ingestDaemonOutput(ProxyShare.daemonID, openLine("192.168.31.42:1000", sid: "a"))
        proxy.ingestDaemonOutput(UUID(), openLine("192.168.31.77:2000", sid: "b"))
        monitor.publishNow()

        XCTAssertEqual(proxy.proxyClients.map(\.ip), ["192.168.31.42"],
                       "another daemon printing gost-shaped JSON must not invent a client")
        XCTAssertEqual(proxy.connectedClientCount, 1)
    }

    func testStoppingTheShareEmptiesTheList() {
        let monitor = ProxyClientMonitor(naming: FakeProxyClientNaming(),
                                         publishInterval: .seconds(3600),
                                         sweepInterval: .seconds(3600))
        // shareConfigFile: `stopShare()` below unconditionally calls `.remove()` on it — without
        // this override that is an unlink() on the REAL ~/Library/Application Support/DevDeck/gost.json.
        let proxy = ProxyManager(discovering: FakeProxyDiscovering(),
                                 advertiser: FakeProxyAdvertising(),
                                 credentials: FakeProxyCredentialStore(),
                                 shareConfigFile: FakePrivateFile(),
                                 clientMonitor: monitor)

        proxy.ingestDaemonOutput(ProxyShare.daemonID, openLine("192.168.31.42:1000", sid: "a"))
        monitor.publishNow()
        XCTAssertEqual(proxy.connectedClientCount, 1)

        proxy.stopShare()
        XCTAssertTrue(proxy.proxyClients.isEmpty)
    }
}
