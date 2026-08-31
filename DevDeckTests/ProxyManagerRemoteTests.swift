import XCTest
@testable import DevDeck

/// Remote (SSH) proxy lifecycle: selecting one holds TWO daemons — the user-visible ssh tunnel
/// and the synthetic bridge — and everything downstream (routing, the env file for `dp`) resolves
/// to the bridge's loopback endpoint only while both are alive.
@MainActor
final class ProxyManagerRemoteTests: XCTestCase {

    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private static let fastPolicy = SupervisionPolicy(
        restartDelays: [.milliseconds(40), .milliseconds(40), .milliseconds(40)],
        stabilityWindow: .milliseconds(150),
        adoptedPollInterval: .milliseconds(30),
        portFreePollInterval: .milliseconds(10),
        portFreeTimeout: .milliseconds(100)
    )

    @MainActor
    private struct Rig {
        let manager: ProxyManager
        let store: CommandStore
        let processManager: ProcessManager
        let runner: FakeCommandRunner
        let bridgeConfig: FakePrivateFile
        let envFile: FakePrivateFile

        /// The remote proxy created through the manager's own add flow.
        var remote: RemoteProxy { store.config.remoteProxies[0] }
        var tunnelController: FakeCommandRunner.Controller? {
            remote.tunnelCommandID.flatMap { runner.controller(for: $0) }
        }
        var bridgeController: FakeCommandRunner.Controller? {
            runner.controller(for: RemoteProxy.bridgeDaemonID)
        }

        /// Drive both daemons to `daemonRunning`, the state routing requires.
        func bringBothUp() async {
            await sleepUntil({ runner.startedCommandIDs.count >= 2 },
                             message: "tunnel and bridge were not both launched")
            tunnelController?.started(pid: 42)
            bridgeController?.started(pid: nil)
            await yieldUntil {
                guard let tunnelID = remote.tunnelCommandID else { return false }
                return processManager.states[tunnelID] == .daemonRunning
                    && processManager.states[RemoteProxy.bridgeDaemonID] == .daemonRunning
            }
        }
    }

    private func makeRig(lanIP: String? = "192.168.1.42") -> Rig {
        let store = CommandStore(configURL: url)
        let runner = FakeCommandRunner()
        let processManager = ProcessManager(runner: runner, notifier: FakeNotifier(),
                                           reaper: FakeDaemonReaper(),
                                           portInspector: FakePortInspector(),
                                           policy: Self.fastPolicy)
        let bridgeConfig = FakePrivateFile(url: URL(fileURLWithPath: "/fake/proxy-bridge.json"))
        let envFile = FakePrivateFile()
        let manager = ProxyManager(
            discovering: FakeProxyDiscovering(),
            advertiser: FakeProxyAdvertising(),
            credentials: FakeProxyCredentialStore(),
            lanIP: { lanIP },
            gostPath: { _ in nil },
            exitIPProbe: { _ in nil },
            exitIPRetryDelay: .milliseconds(1),
            envFile: envFile,
            shareConfigFile: FakePrivateFile(),
            bridgeConfigFile: bridgeConfig
        )
        manager.store = store
        manager.processManager = processManager
        return Rig(manager: manager, store: store, processManager: processManager,
                   runner: runner, bridgeConfig: bridgeConfig, envFile: envFile)
    }

    /// Add through the manager and select — the setup most tests start from.
    private func addAndSelect(_ rig: Rig) {
        rig.manager.addRemoteProxy(name: "vds", destination: "user@vds",
                                   localPort: 18888, socksPort: 1080)
        rig.manager.setActiveRemoteProxy(rig.remote)
    }

    // MARK: - Creation

    func testAddRemoteProxyCreatesLinkedTunnelCommand() {
        let rig = makeRig()

        rig.manager.addRemoteProxy(name: "vds", destination: "user@vds",
                                   localPort: 18888, socksPort: 1080)

        let remote = rig.remote
        XCTAssertEqual(remote.name, "vds")
        let tunnelID = remote.tunnelCommandID
        let command = tunnelID.flatMap { rig.store.commandsByID[$0] }
        XCTAssertEqual(command?.command, "ssh -N -D 127.0.0.1:1080 user@vds")
        XCTAssertEqual(command?.isDaemon, true)
        XCTAssertEqual(command?.watchdogEnabled, true, "the tunnel must self-heal like any daemon")
        XCTAssertEqual(command?.port, 1080, "the occupied-port machinery guards the SOCKS port")
    }

    // MARK: - Lifecycle

    func testSelectingStartsTunnelAndBridge() async {
        let rig = makeRig()
        addAndSelect(rig)

        await sleepUntil({ rig.runner.startedCommandIDs.count >= 2 },
                         message: "expected both daemons to launch")

        let remote = rig.remote
        XCTAssertEqual(Set(rig.runner.startedCommandIDs),
                       Set([remote.tunnelCommandID!, RemoteProxy.bridgeDaemonID]))
        let bridgeCommand = rig.bridgeController?.command
        XCTAssertEqual(bridgeCommand?.command,
                       ProxyShare.builtInCommandPrefix + "/fake/proxy-bridge.json")
        XCTAssertEqual(bridgeCommand?.port, 18888)
        // The bridge config is on disk BEFORE the launch, with the SOCKS upstream in it.
        XCTAssertEqual(rig.bridgeConfig.contents?.contains(#""upstreamSocks":"127.0.0.1:1080""#), true)
        XCTAssertEqual(rig.bridgeConfig.contents?.contains(#""addr":":18888""#), true)
    }

    func testRoutingIsUnavailableUntilBothDaemonsAreUp() async {
        let rig = makeRig()
        addAndSelect(rig)
        await sleepUntil({ rig.runner.startedCommandIDs.count >= 2 },
                         message: "expected both daemons to launch")
        let flagged = Command(name: "claude", command: "claude", routeThroughProxy: true)

        XCTAssertEqual(rig.manager.routing(for: flagged), .unavailable,
                       "started-but-not-running daemons must not route")

        rig.tunnelController?.started(pid: 42)
        await yieldUntil {
            rig.processManager.states[rig.remote.tunnelCommandID!] == .daemonRunning
        }
        XCTAssertEqual(rig.manager.routing(for: flagged), .unavailable,
                       "the tunnel alone is not enough — the bridge is the endpoint")
    }

    func testRoutingRoutesThroughTheBridgeWhenBothAreUp() async {
        let rig = makeRig()
        addAndSelect(rig)
        await rig.bringBothUp()
        let flagged = Command(name: "claude", command: "claude", routeThroughProxy: true)

        guard case .routed(let env) = rig.manager.routing(for: flagged) else {
            return XCTFail("expected .routed, got \(rig.manager.routing(for: flagged))")
        }
        XCTAssertEqual(env["HTTPS_PROXY"], "http://127.0.0.1:18888")
        XCTAssertEqual(env["ALL_PROXY"], "http://127.0.0.1:18888")
    }

    func testEnvFileIsNetworkIndependentEvenWithoutLAN() async {
        // No LAN address at all — a remote proxy must still serve `dp`: loopback needs no LAN.
        let rig = makeRig(lanIP: nil)
        addAndSelect(rig)
        await rig.bringBothUp()

        await sleepUntil({ rig.envFile.contents != nil },
                         message: "proxy.env was never written for the remote proxy")
        XCTAssertEqual(rig.envFile.contents?.contains("DEVDECK_PROXY_URL=http://127.0.0.1:18888"), true)
        XCTAssertEqual(rig.envFile.contents?.contains("DEVDECK_PROXY_LAN=*"), true)
    }

    func testDeselectingStopsBothAndCleansUp() async {
        let rig = makeRig()
        addAndSelect(rig)
        await rig.bringBothUp()
        await sleepUntil({ rig.envFile.contents != nil },
                         message: "precondition: env file written while usable")

        rig.manager.setActiveRemoteProxy(nil)

        XCTAssertEqual(rig.tunnelController?.stopCount, 1)
        XCTAssertEqual(rig.bridgeController?.stopCount, 1)
        XCTAssertNil(rig.bridgeConfig.contents, "the bridge config must not outlive the selection")
        await sleepUntil({ rig.envFile.contents == nil },
                         message: "proxy.env must be removed when nothing is selected")
    }

    func testSelectingADiscoveredProxyStopsTheRemotePair() async {
        let rig = makeRig()
        addAndSelect(rig)
        await rig.bringBothUp()

        let discovered = DiscoveredProxy(name: "colleague-mac", host: "192.168.1.5", port: 9999,
                                         authRequired: false, exitIP: nil,
                                         proto: "http", schema: proxyTXTSchemaVersion)
        rig.manager.setActiveProxy(discovered)

        XCTAssertEqual(rig.tunnelController?.stopCount, 1)
        XCTAssertEqual(rig.bridgeController?.stopCount, 1)
        XCTAssertNil(rig.bridgeConfig.contents)
        XCTAssertNil(rig.store.config.settings.activeRemoteProxyID)
        XCTAssertEqual(rig.store.config.settings.activeProxyName, "colleague-mac")
    }

    // MARK: - Editing (the edit sheet reaches `applyRemoteProxyEdit`)

    func testApplyRemoteProxyEditRewritesTheTunnelWhenSafe() {
        let rig = makeRig()
        rig.manager.addRemoteProxy(name: "vds", destination: "user@old-vds",
                                   localPort: 18888, socksPort: 1080)
        var updated = rig.remote
        updated.name = "renamed"
        updated.socksPort = 2080
        let newCommand = RemoteProxy.tunnelCommandString(destination: "user@new-vds", socksPort: 2080)

        rig.manager.applyRemoteProxyEdit(updated, tunnelCommandUpdate: .rewrite(newCommand))

        XCTAssertEqual(rig.store.config.remoteProxies.first?.name, "renamed")
        XCTAssertEqual(rig.store.config.remoteProxies.first?.socksPort, 2080)
        XCTAssertEqual(rig.store.commandsByID[updated.tunnelCommandID!]?.command, newCommand)
    }

    func testApplyRemoteProxyEditLeavesAHandEditedTunnelCommandUntouched() {
        let rig = makeRig()
        rig.manager.addRemoteProxy(name: "vds", destination: "user@vds",
                                   localPort: 18888, socksPort: 1080)
        var tunnel = rig.store.commandsByID[rig.remote.tunnelCommandID!]!
        tunnel.command += " -o ServerAliveInterval=30"
        rig.store.upsert(tunnel)
        var updated = rig.remote
        updated.name = "renamed"

        rig.manager.applyRemoteProxyEdit(updated, tunnelCommandUpdate: .handEdited)

        XCTAssertEqual(rig.store.config.remoteProxies.first?.name, "renamed",
                       "name/ports are saved regardless of the tunnel command's fate")
        XCTAssertEqual(rig.store.commandsByID[rig.remote.tunnelCommandID!]?.command, tunnel.command,
                       "a hand-edited tunnel command must never be silently overwritten")
    }

    func testApplyRemoteProxyEditOnAnActiveProxyRestartsWithTheNewCommandAlreadyPersisted() async {
        let rig = makeRig()
        addAndSelect(rig)
        await rig.bringBothUp()
        var updated = rig.remote
        updated.socksPort = 2080
        let newCommand = RemoteProxy.tunnelCommandString(destination: "user@vds", socksPort: 2080)

        rig.manager.applyRemoteProxyEdit(updated, tunnelCommandUpdate: .rewrite(newCommand))

        // Both the proxy and the tunnel command must be on disk before the relaunch, and the
        // relaunch itself must actually happen — a restart that reads stale state and never
        // re-runs would silently leave the tunnel dead.
        await sleepUntil({ rig.tunnelController?.command.command == newCommand },
                         message: "expected the tunnel to be relaunched with the edited command")
        XCTAssertEqual(rig.store.commandsByID[updated.tunnelCommandID!]?.command, newCommand)
        XCTAssertEqual(rig.store.config.remoteProxies.first?.socksPort, 2080)
    }

    func testStartBringsASelectedRemoteProxyUpOnLaunch() async {
        let rig = makeRig()
        addAndSelect(rig)
        await sleepUntil({ rig.runner.startedCommandIDs.count >= 2 }, message: "setup launch")
        // Simulate a fresh app session: same persisted config, new store + manager instances.
        let relaunched = makeRig()
        relaunched.store.start()   // the app loads the config before ProxyManager.start()

        relaunched.manager.start()

        await sleepUntil({ relaunched.runner.startedCommandIDs.count >= 2 },
                         message: "a selected remote proxy must come up at launch, like the share")
        XCTAssertTrue(relaunched.runner.startedCommandIDs.contains(RemoteProxy.bridgeDaemonID))
    }
}
