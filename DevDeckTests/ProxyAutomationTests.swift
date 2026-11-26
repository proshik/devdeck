import XCTest
@testable import DevDeck

/// `DevDeck automation proxy …` over the real `ProxyManager` and `ProcessManager` state machine,
/// with fake discovery, Keychain, files and runner — no mDNS, no processes, no network.
@MainActor
final class ProxyAutomationTests: XCTestCase {

    private var dir: URL!
    private var store: CommandStore!
    private var runner: FakeCommandRunner!
    private var processManager: ProcessManager!
    private var discovery: FakeProxyDiscovering!
    private var credentials: FakeProxyCredentialStore!
    private var portInspector: FakePortInspector!
    private var manager: ProxyManager!
    /// What the exit-IP probe answers; read off the main actor, hence the lock.
    private let exitIPBox = ExitIPBox()
    private var exitIP: String? {
        get { exitIPBox.value }
        set { exitIPBox.value = newValue }
    }

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = CommandStore(configURL: dir.appendingPathComponent("config.json"))
        runner = FakeCommandRunner()
        portInspector = FakePortInspector()
        processManager = ProcessManager(runner: runner, notifier: FakeNotifier(), reaper: FakeDaemonReaper(),
                                        portInspector: portInspector)
        discovery = FakeProxyDiscovering()
        credentials = FakeProxyCredentialStore()
        exitIP = "203.0.113.7"
        manager = ProxyManager(discovering: discovery, advertiser: FakeProxyAdvertising(), credentials: credentials,
                               lanIP: { "192.168.1.42" }, gostPath: { _ in nil },
                               exitIPProbe: { [box = exitIPBox] _ in box.probe() },
                               exitIPAttempts: 1, exitIPRetryDelay: .milliseconds(1),
                               envFile: FakePrivateFile(), shareConfigFile: FakePrivateFile(),
                               bridgeConfigFile: FakePrivateFile(url: URL(fileURLWithPath: "/fake/proxy-bridge.json")))
        manager.store = store
        manager.processManager = processManager
        try update { $0.settings.automationEnabled = true; $0.settings.automationProxyEnabled = true }
    }

    override func tearDownWithError() throws {
        manager.stopDiscovery()
        try? FileManager.default.removeItem(at: dir)
    }

    private func update(_ change: (inout Config) -> Void) throws {
        var config = store.config
        change(&config)
        try store.save(config)
    }

    private func automation(startWait: Duration = .seconds(5)) -> ProxyAutomation {
        ProxyAutomation(proxy: manager, config: { [unowned self] in self.store.config },
                        startWait: startWait, checkWait: .seconds(5), stopWait: .seconds(2),
                        pollInterval: .milliseconds(5))
    }

    private func handle(_ request: AutomationProxyRequest, startWait: Duration = .seconds(5)) async -> AutomationResponse {
        await automation(startWait: startWait).handle(request)
    }

    private func blocks(_ response: AutomationResponse) -> [[String: String]] {
        response.stdout.components(separatedBy: "\n\n").map { block in
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                guard let colon = line.range(of: ": ") else { continue }
                fields[String(line[..<colon.lowerBound])] = String(line[colon.upperBound...])
            }
            return fields
        }
    }

    private func lan(_ name: String, auth: Bool = false) -> DiscoveredProxy {
        DiscoveredProxy(name: name, host: "192.168.1.50", port: 9999, authRequired: auth, exitIP: "198.51.100.1",
                        proto: "http", schema: proxyTXTSchemaVersion)
    }

    private func announce(_ proxies: [DiscoveredProxy]) async {
        manager.setDiscoveryEnabled(true)
        discovery.emit(proxies)
        await yieldUntil { manager.visibleProxies.count == proxies.count }
    }

    /// A remote proxy whose tunnel and bridge come up as soon as they are launched.
    @discardableResult
    private func addRemote(_ name: String = "vds", eager: Bool = true) -> RemoteProxy {
        manager.addRemoteProxy(name: name, destination: "user@vds", localPort: 18888, socksPort: 1080)
        let remote = store.config.remoteProxies.first { $0.name == name }!
        if eager {
            runner.eagerScripts[remote.tunnelCommandID!] = [.started(pid: 42)]
            runner.eagerScripts[RemoteProxy.bridgeDaemonID] = [.started(pid: nil)]
        }
        return remote
    }

    // MARK: access

    func testSwitchesOffRefuseEveryActionAndChangeNothing() async throws {
        let actions: [AutomationProxyRequest] = [
            .init(action: .list), .init(action: .status), .init(action: .use, target: "none"), .init(action: .check),
            .init(action: .shareOn), .init(action: .shareOff), .init(action: .shareStatus), .init(action: .shareSet, port: 8080),
        ]
        for (master, proxy, refusal) in [(false, true, AutomationRefusal.automationDisabled),
                                         (true, false, AutomationRefusal.proxyAutomationDisabled)] {
            try update { $0.settings.automationEnabled = master; $0.settings.automationProxyEnabled = proxy }
            let before = store.config
            for request in actions {
                let response = await handle(request)
                XCTAssertEqual(response.exitCode, AutomationExitCode.refused, "\(request.action)")
                XCTAssertEqual(response.stderr, refusal.message)
                XCTAssertEqual(response.stdout, "")
            }
            XCTAssertEqual(store.config, before)
            XCTAssertTrue(runner.startedCommandIDs.isEmpty)
        }
    }

    func testProxySwitchDefaultsOffAndDecodesWithDefault() throws {
        XCTAssertFalse(Settings().automationProxyEnabled)
        XCTAssertFalse(Settings().automationAwakeEnabled)
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertFalse(decoded.automationProxyEnabled)
        XCTAssertFalse(decoded.automationAwakeEnabled)
        var settings = Settings()
        settings.automationProxyEnabled = true
        settings.automationAwakeEnabled = true
        let round = try JSONDecoder().decode(Settings.self, from: JSONEncoder().encode(settings))
        XCTAssertTrue(round.automationProxyEnabled)
        XCTAssertTrue(round.automationAwakeEnabled)
    }

    // MARK: list / status

    func testListShowsLanAndRemoteProxies() async {
        await announce([lan("Office Mac", auth: true)])
        let remote = addRemote()
        let response = await handle(.init(action: .list))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        let list = blocks(response)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0]["name"], "Office Mac")
        XCTAssertEqual(list[0]["type"], "lan")
        XCTAssertEqual(list[0]["auth"], "yes")
        XCTAssertEqual(list[0]["live"], "yes")
        XCTAssertEqual(list[0]["active"], "no")
        XCTAssertEqual(list[0]["endpoint"], "192.168.1.50:9999")
        XCTAssertEqual(list[1]["name"], "vds")
        XCTAssertEqual(list[1]["type"], "remote")
        XCTAssertEqual(list[1]["id"], remote.id.uuidString)
        XCTAssertEqual(list[1]["live"], "no")
        XCTAssertEqual(list[1]["endpoint"], "127.0.0.1:18888")
    }

    func testEmptyListExplainsDiscoveryOff() async {
        let response = await handle(.init(action: .list))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(response.stdout, "")
        XCTAssertEqual(response.stderr, L10n.automationProxyListEmpty(discoveryOn: false))
    }

    func testStatusHasClientAndShareBlocks() async {
        let response = await handle(.init(action: .status))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        let parts = blocks(response)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[0]["proxy"], "none")
        XCTAssertEqual(parts[0]["usable"], "no")
        XCTAssertEqual(parts[1]["share"], "off")
        XCTAssertEqual(parts[1]["state"], "idle")
        XCTAssertEqual(parts[1]["port"], "9999")
        XCTAssertEqual(parts[1]["clients"], "0")
        XCTAssertNil(parts[1]["password"], "no password line while auth is off")
    }

    // MARK: use — LAN

    func testUseLanProxyWithoutAuthSelectsIt() async {
        await announce([lan("Office Mac")])
        let response = await handle(.init(action: .use, target: "Office Mac"))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success, response.stderr)
        XCTAssertEqual(store.config.settings.activeProxyName, "Office Mac")
        XCTAssertEqual(blocks(response)[0]["usable"], "yes")
        XCTAssertEqual(manager.routing(for: Command(name: "x", command: "x", routeThroughProxy: true)),
                       .routed(env: proxyEnv(host: "192.168.1.50", port: 9999, user: nil, pass: nil)))
    }

    func testUseLanProxyNeedingCredentialsIsRefusedUnchanged() async throws {
        await announce([lan("Locked", auth: true)])
        // A password alone is not enough: the username belongs to the current choice only.
        credentials.setPassword("secret", for: ProxyCredentialAccount.client("Locked"))
        let response = await handle(.init(action: .use, target: "Locked"))
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(response.stderr, AutomationRefusal.proxyCredentialsMissing("Locked").message)
        XCTAssertNil(store.config.settings.activeProxyName)
        XCTAssertFalse(response.stderr.contains("secret"))
    }

    func testUseLanProxyWithSavedCredentialsIsIdempotent() async throws {
        await announce([lan("Locked", auth: true)])
        manager.setActiveProxy(manager.visibleProxies[0])
        manager.setClientCredentials(username: "ann", password: "secret", for: "Locked")
        let response = await handle(.init(action: .use, target: "Locked"))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success, response.stderr)
        XCTAssertEqual(store.config.settings.activeProxyUsername, "ann", "re-selecting keeps the saved username")
        let fields = blocks(response)[0]
        XCTAssertEqual(fields["credentials"], "saved")
        XCTAssertEqual(fields["usable"], "yes")
        XCTAssertFalse(response.stdout.contains("secret"), "the answer never carries a password")
    }

    func testChoosingLanProxyStopsTheRemoteTunnel() async throws {
        let remote = addRemote()
        await announce([lan("Office Mac")])
        _ = await handle(.init(action: .use, target: "vds"))
        let tunnel = try XCTUnwrap(runner.controller(for: remote.tunnelCommandID!))
        let response = await handle(.init(action: .use, target: "Office Mac"))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertNil(store.config.settings.activeRemoteProxyID)
        XCTAssertEqual(tunnel.stopCount, 1, "choosing a LAN proxy stops the tunnel, as in the popover")
        XCTAssertEqual(runner.controller(for: RemoteProxy.bridgeDaemonID)?.stopCount, 1)
    }

    // MARK: use — remote

    func testUseRemoteStartsTunnelAndBridgeAndWaitsForThem() async {
        let remote = addRemote()
        let response = await handle(.init(action: .use, target: remote.id.uuidString.lowercased()))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success, response.stdout + response.stderr)
        XCTAssertEqual(Set(runner.startedCommandIDs), [remote.tunnelCommandID!, RemoteProxy.bridgeDaemonID])
        let fields = blocks(response)[0]
        XCTAssertEqual(fields["proxy"], "vds")
        XCTAssertEqual(fields["type"], "remote")
        XCTAssertEqual(fields["tunnel"], "daemonRunning")
        XCTAssertEqual(fields["bridge"], "daemonRunning")
        XCTAssertEqual(fields["usable"], "yes")
    }

    func testUseRemoteReportsAFailedTunnelWithItsOutput() async {
        let remote = addRemote(eager: false)
        runner.eagerScripts[remote.tunnelCommandID!] = [.line("Permission denied (publickey).", stream: .stderr),
                                                       .terminated(exitCode: 255)]
        runner.eagerScripts[RemoteProxy.bridgeDaemonID] = [.started(pid: nil)]
        let response = await handle(.init(action: .use, target: "vds"))
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed)
        XCTAssertEqual(store.config.settings.activeRemoteProxyID, remote.id, "the choice is made, like a click")
        XCTAssertTrue(response.stdout.contains("Permission denied (publickey)."), response.stdout)
        XCTAssertEqual(blocks(response)[0]["message"], L10n.automationRemoteFailed("vds"))
    }

    func testUseRemoteThatDoesNotComeUpTimesOut() async {
        addRemote(eager: false)
        let response = await handle(.init(action: .use, target: "vds"), startWait: .milliseconds(100))
        XCTAssertEqual(response.exitCode, AutomationExitCode.timedOut)
        XCTAssertEqual(blocks(response)[0]["tunnel"], "running")
    }

    func testUseRemoteWithAnOccupiedPortFails() async {
        addRemote(eager: false)
        portInspector.occupants[1080] = PortOccupant(pid: 777, processName: "ssh")
        let response = await handle(.init(action: .use, target: "vds"))
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed)
        XCTAssertEqual(blocks(response)[0]["portOwner"], "ssh (PID 777)")
    }

    func testRemoteWithoutTunnelCommandIsRefused() async throws {
        let remote = addRemote()
        store.delete(commandID: remote.tunnelCommandID!)
        let response = await handle(.init(action: .use, target: "vds"))
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(response.stderr, AutomationRefusal.remoteTunnelMissing("vds").message)
        XCTAssertNil(store.config.settings.activeRemoteProxyID)
    }

    func testUseNoneClearsRemoteAndStopsItsDaemons() async throws {
        let remote = addRemote()
        _ = await handle(.init(action: .use, target: "vds"))
        let response = await handle(.init(action: .use, target: "none"))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertNil(store.config.settings.activeRemoteProxyID)
        XCTAssertEqual(runner.controller(for: remote.tunnelCommandID!)?.stopCount, 1)
        XCTAssertEqual(blocks(response)[0]["proxy"], "none")
        XCTAssertEqual(blocks(response)[0]["message"], L10n.automationProxyCleared)
    }

    func testUseNoneClearsLanSelection() async {
        await announce([lan("Office Mac")])
        _ = await handle(.init(action: .use, target: "Office Mac"))
        let response = await handle(.init(action: .use, target: "none"))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertNil(store.config.settings.activeProxyName)
    }

    func testUnknownAndAmbiguousNamesAreRefusedWithAList() async {
        await announce([lan("vds")])
        let remote = addRemote("vds")
        let unknown = await handle(.init(action: .use, target: "nope"))
        XCTAssertEqual(unknown.exitCode, AutomationExitCode.refused)
        XCTAssertTrue(unknown.stderr.contains("lan\tvds\t-"), unknown.stderr)
        XCTAssertTrue(unknown.stderr.contains("remote\tvds\t\(remote.id.uuidString)"), unknown.stderr)

        let ambiguous = await handle(.init(action: .use, target: "vds"))
        XCTAssertEqual(ambiguous.exitCode, AutomationExitCode.refused)
        XCTAssertTrue(ambiguous.stderr.hasPrefix(L10n.automationAmbiguousProxy("vds", [])), ambiguous.stderr)
        XCTAssertNil(store.config.settings.activeProxyName)
        XCTAssertNil(store.config.settings.activeRemoteProxyID)

        let byID = await handle(.init(action: .use, target: remote.id.uuidString))
        XCTAssertEqual(byID.exitCode, AutomationExitCode.success, "a UUID settles it")
    }

    // MARK: check

    func testCheckWithoutAProxyIsRefused() async {
        let response = await handle(.init(action: .check))
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(response.stderr, L10n.proxyCheckUnavailableNoProxy)
    }

    func testCheckPrintsExitIPOrFails() async {
        await announce([lan("Office Mac")])
        _ = await handle(.init(action: .use, target: "Office Mac"))
        let ok = await handle(.init(action: .check))
        XCTAssertEqual(ok.exitCode, AutomationExitCode.success)
        XCTAssertEqual(blocks(ok)[0]["status"], "ok")
        XCTAssertEqual(blocks(ok)[0]["exitIP"], "203.0.113.7")

        exitIP = nil
        let failed = await handle(.init(action: .check))
        XCTAssertEqual(failed.exitCode, AutomationExitCode.failed)
        XCTAssertEqual(blocks(failed)[0]["status"], "failed")
    }

    // MARK: share

    func testShareOnStartsTheListenerAndOffStopsIt() async {
        runner.eagerScripts[ProxyShare.daemonID] = [.started(pid: nil)]
        let on = await handle(.init(action: .shareOn))
        XCTAssertEqual(on.exitCode, AutomationExitCode.success, on.stdout)
        XCTAssertTrue(store.config.settings.proxyShareEnabled)
        XCTAssertEqual(blocks(on)[0]["state"], "daemonRunning")
        XCTAssertEqual(blocks(on)[0]["share"], "on")

        let again = await handle(.init(action: .shareOn))
        XCTAssertEqual(again.exitCode, AutomationExitCode.success)
        XCTAssertEqual(runner.startedCommandIDs, [ProxyShare.daemonID], "a running share is not started twice")

        let off = await handle(.init(action: .shareOff))
        XCTAssertEqual(off.exitCode, AutomationExitCode.success, off.stdout)
        XCTAssertFalse(store.config.settings.proxyShareEnabled)
        XCTAssertEqual(blocks(off)[0]["state"], "idle")
    }

    func testShareOnWithAuthButNoPasswordIsRefused() async throws {
        try update { $0.proxy.authEnabled = true; $0.proxy.username = "ann" }
        let response = await handle(.init(action: .shareOn))
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(response.stderr, AutomationRefusal.sharePasswordMissing.message)
        XCTAssertFalse(store.config.settings.proxyShareEnabled)
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }

    func testShareOnWithGostMissingIsRefused() async throws {
        try update { $0.proxy.engine = .gost }
        let response = await handle(.init(action: .shareOn))
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(response.stderr, AutomationRefusal.gostMissing.message)
        XCTAssertFalse(store.config.settings.proxyShareEnabled)
    }

    func testShareSetRestartsARunningShareWithTheNewPort() async throws {
        runner.eagerScripts[ProxyShare.daemonID] = [.started(pid: nil)]
        _ = await handle(.init(action: .shareOn))
        let response = await handle(.init(action: .shareSet, port: 8899, serviceName: "Lab"))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success, response.stdout)
        XCTAssertEqual(store.config.proxy.port, 8899)
        XCTAssertEqual(store.config.proxy.serviceName, "Lab")
        XCTAssertEqual(runner.startedCommandIDs, [ProxyShare.daemonID, ProxyShare.daemonID], "restarted once")
        XCTAssertEqual(runner.controller(for: ProxyShare.daemonID)?.command.port, 8899)
        let fields = blocks(response)[0]
        XCTAssertEqual(fields["restarted"], "yes")
        XCTAssertEqual(fields["state"], "daemonRunning")
        XCTAssertEqual(fields["port"], "8899")
    }

    func testShareSetOnAStoppedShareOnlySaves() async {
        let response = await handle(.init(action: .shareSet, port: 8899, engine: .builtIn))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(store.config.proxy.port, 8899)
        XCTAssertEqual(blocks(response)[0]["restarted"], "no")
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
    }

    func testShareSetAuthOnNeedsAKeychainPasswordAndAUsername() async {
        let noPassword = await handle(.init(action: .shareSet, auth: true, username: "ann"))
        XCTAssertEqual(noPassword.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(noPassword.stderr, AutomationRefusal.sharePasswordMissing.message)
        XCTAssertFalse(store.config.proxy.authEnabled, "a refusal saves nothing")

        manager.setSharePassword("pw")
        let noUsername = await handle(.init(action: .shareSet, auth: true))
        XCTAssertEqual(noUsername.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(noUsername.stderr, AutomationRefusal.shareUsernameMissing.message)

        let ok = await handle(.init(action: .shareSet, auth: true, username: "ann"))
        XCTAssertEqual(ok.exitCode, AutomationExitCode.success)
        XCTAssertTrue(store.config.proxy.authEnabled)
        XCTAssertEqual(blocks(ok)[0]["password"], "saved")
        XCTAssertFalse(ok.stdout.contains("pw\n"))

        let off = await handle(.init(action: .shareSet, auth: false))
        XCTAssertEqual(off.exitCode, AutomationExitCode.success)
        XCTAssertEqual(manager.sharePassword(), "pw", "the command line never deletes a saved password")
    }

    func testShareSetGostWithoutGostIsRefused() async {
        let response = await handle(.init(action: .shareSet, engine: .gost))
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(store.config.proxy.engine, .builtIn)
    }

    func testShareSetWithTheSavedValuesChangesNothing() async {
        runner.eagerScripts[ProxyShare.daemonID] = [.started(pid: nil)]
        _ = await handle(.init(action: .shareOn))
        let response = await handle(.init(action: .shareSet, port: 9999))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(blocks(response)[0]["restarted"], "no")
        XCTAssertEqual(runner.startedCommandIDs.count, 1, "no restart for an unchanged share")
    }

    func testHandMadeRequestsAreValidatedAppSide() async {
        let port = await handle(.init(action: .shareSet, port: 0))
        XCTAssertEqual(port.exitCode, AutomationExitCode.usage)
        let empty = await handle(.init(action: .shareSet))
        XCTAssertEqual(empty.exitCode, AutomationExitCode.usage)
        let use = await handle(.init(action: .use))
        XCTAssertEqual(use.exitCode, AutomationExitCode.usage)
    }

    // MARK: review round 1

    func testANotLiveRemoteChoiceIsListedOnceAndResolvesByName() async throws {
        addRemote(eager: false)
        _ = await handle(.init(action: .use, target: "vds"), startWait: .milliseconds(50))
        let list = blocks(await handle(.init(action: .list)))
        XCTAssertEqual(list.count, 1, "the synthetic loopback entry is not a LAN proxy")
        XCTAssertEqual(list[0]["type"], "remote")
        let again = await handle(.init(action: .use, target: "vds"), startWait: .milliseconds(50))
        XCTAssertNotEqual(again.exitCode, AutomationExitCode.refused, again.stderr)
    }

    func testACheckReplacedByAnotherProxysCheckFails() async throws {
        await announce([lan("A"), lan("B")])
        _ = await handle(.init(action: .use, target: "A"))
        exitIPBox.delay = 0.3
        let first = Task { await self.handle(.init(action: .check)) }
        try await Task.sleep(for: .milliseconds(50))
        manager.setActiveProxy(manager.visibleProxies.first { $0.name == "B" })
        manager.checkActiveProxy()
        let response = await first.value
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed, response.stdout)
        XCTAssertEqual(blocks(response)[0]["message"], L10n.automationProxySelectionChanged)
    }

    func testShareOnRefusesARunningShareWithAuthButNoUsername() async throws {
        runner.eagerScripts[ProxyShare.daemonID] = [.started(pid: nil)]
        _ = await handle(.init(action: .shareOn))
        try update { $0.proxy.authEnabled = true; $0.proxy.username = "" }
        let response = await handle(.init(action: .shareOn))
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(response.stderr, AutomationRefusal.shareUsernameMissing.message)
    }

    func testShareOnWhileTheListenerIsStillStoppingStartsANewOne() async throws {
        runner.eagerScripts[ProxyShare.daemonID] = [.started(pid: nil)]
        runner.autoTerminateOnStopCode = nil   // read at launch: the listener takes its time to exit
        _ = await handle(.init(action: .shareOn))
        let dying = try XCTUnwrap(runner.controller(for: ProxyShare.daemonID))
        manager.setShareEnabled(false)   // stop requested; the listener has not exited yet
        let on = Task { await self.handle(.init(action: .shareOn)) }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(runner.startedCommandIDs.count, 1, "no start while the old listener is stopping")
        dying.terminate(0)
        let response = await on.value
        XCTAssertEqual(response.exitCode, AutomationExitCode.success, response.stdout)
        XCTAssertEqual(runner.startedCommandIDs.count, 2)
        XCTAssertEqual(blocks(response)[0]["state"], "daemonRunning")
    }

    func testChangesAreRefusedWhileTheConfigFileDoesNotDecode() async throws {
        await announce([lan("Office Mac")])
        try Data("{ not json".utf8).write(to: dir.appendingPathComponent("config.json"))
        store.reload()
        XCTAssertTrue(store.isFileDamaged)
        for request in [AutomationProxyRequest(action: .use, target: "Office Mac"), .init(action: .shareOn),
                        .init(action: .shareSet, port: 8899)] {
            let response = await handle(request)
            XCTAssertEqual(response.exitCode, AutomationExitCode.refused, "\(request.action)")
            XCTAssertTrue(response.stderr.hasPrefix(L10n.automationConfigNotSaved("").trimmingCharacters(in: .whitespaces)),
                          response.stderr)
        }
        XCTAssertNil(store.config.settings.activeProxyName)
        XCTAssertTrue(runner.startedCommandIDs.isEmpty)
        let status = await handle(.init(action: .status))
        XCTAssertEqual(status.exitCode, AutomationExitCode.success, "reading still works")
    }

    func testControlCharactersFromTheNetworkNeverReachTheOutput() async {
        await announce([DiscoveredProxy(name: "evil\u{1B}[2J", host: "192.168.1.9", port: 1, authRequired: false,
                                        exitIP: "1.2.3.4\u{07}", proto: "http", schema: proxyTXTSchemaVersion)])
        let response = await handle(.init(action: .list))
        XCTAssertFalse(response.stdout.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" })
        let unknown = await handle(.init(action: .use, target: "x"))
        XCTAssertFalse(unknown.stderr.contains("\u{1B}"))
    }

    // MARK: review round 2

    func testShareOnRechecksCredentialsAfterWaitingForTheOldListener() async throws {
        runner.eagerScripts[ProxyShare.daemonID] = [.started(pid: nil)]
        runner.autoTerminateOnStopCode = nil
        _ = await handle(.init(action: .shareOn))
        let dying = try XCTUnwrap(runner.controller(for: ProxyShare.daemonID))
        manager.setShareEnabled(false)
        let on = Task { await self.handle(.init(action: .shareOn)) }
        try await Task.sleep(for: .milliseconds(30))
        try update { $0.proxy.authEnabled = true; $0.proxy.username = "" }   // saved in the UI meanwhile
        dying.terminate(0)
        let response = await on.value
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertEqual(response.stderr, AutomationRefusal.shareUsernameMissing.message)
        XCTAssertFalse(store.config.settings.proxyShareEnabled)
        XCTAssertEqual(runner.startedCommandIDs.count, 1)
    }

    func testUseNoneAnswersOnceThePairHasExited() async throws {
        runner.autoTerminateOnStopCode = nil
        let remote = addRemote()
        _ = await handle(.init(action: .use, target: "vds"))
        let tunnel = try XCTUnwrap(runner.controller(for: remote.tunnelCommandID!))
        let bridge = try XCTUnwrap(runner.controller(for: RemoteProxy.bridgeDaemonID))
        let none = Task { await self.handle(.init(action: .use, target: "none")) }
        try await Task.sleep(for: .milliseconds(50))
        tunnel.terminate(143)
        bridge.terminate(0)
        let response = await none.value
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertNotEqual(processManager.states[remote.tunnelCommandID!], .daemonRunning)
        XCTAssertNotEqual(processManager.states[RemoteProxy.bridgeDaemonID], .daemonRunning)
    }

    func testUseNoneTimesOutWhenThePairDoesNotExit() async {
        runner.autoTerminateOnStopCode = nil
        addRemote()
        _ = await handle(.init(action: .use, target: "vds"))
        let response = await handle(.init(action: .use, target: "none"))
        XCTAssertEqual(response.exitCode, AutomationExitCode.timedOut)
        XCTAssertNil(store.config.settings.activeRemoteProxyID, "the choice is cleared either way")
    }

    func testShareSetWhoseRestartCouldNotLaunchFails() async throws {
        let shareFile = FakePrivateFile()
        manager = ProxyManager(discovering: discovery, advertiser: FakeProxyAdvertising(), credentials: credentials,
                               lanIP: { "192.168.1.42" }, gostPath: { _ in nil }, exitIPProbe: { _ in nil },
                               exitIPAttempts: 1, exitIPRetryDelay: .milliseconds(1),
                               envFile: FakePrivateFile(), shareConfigFile: shareFile, bridgeConfigFile: FakePrivateFile())
        manager.store = store
        manager.processManager = processManager
        runner.eagerScripts[ProxyShare.daemonID] = [.started(pid: nil)]
        runner.autoTerminateOnStopCode = nil
        _ = await handle(.init(action: .shareOn))
        shareFile.writeSucceeds = false
        let response = await handle(.init(action: .shareSet, port: 8899))
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed, response.stdout)
        XCTAssertEqual(blocks(response)[0]["restarted"], "no")
    }

    func testACheckReplacedByAnotherCheckOfTheSameProxyFails() async throws {
        await announce([lan("A")])
        _ = await handle(.init(action: .use, target: "A"))
        exitIPBox.delay = 0.3
        let first = Task { await self.handle(.init(action: .check)) }
        try await Task.sleep(for: .milliseconds(50))
        manager.checkActiveProxy()
        let response = await first.value
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed, response.stdout)
    }

    func testAnHTTPErrorPageIsNoExitIP() async {
        await announce([lan("A")])
        _ = await handle(.init(action: .use, target: "A"))
        exitIP = "<html>503 Service Unavailable</html>"
        let response = await handle(.init(action: .check))
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed)
        XCTAssertNil(blocks(response)[0]["exitIP"])
        XCTAssertTrue(isIPAddress("203.0.113.7"))
        XCTAssertTrue(isIPAddress("2001:db8::1"))
        XCTAssertFalse(isIPAddress("captive.portal"))
        XCTAssertFalse(isIPAddress(""))
    }

    func testAUsernameWithAColonIsRejected() async {
        let response = await handle(.init(action: .shareSet, username: "team:op"))
        XCTAssertEqual(response.exitCode, AutomationExitCode.usage)
        XCTAssertEqual(store.config.proxy.username, "")
    }

    func testRouterReachesProxyAutomation() async {
        let router = AutomationRequestRouter(
            service: AutomationService(manager: processManager, config: { [unowned self] in self.store.config }),
            proxy: automation())
        let response = await router.handle(AutomationRequest(operation: .proxy, proxy: .init(action: .shareStatus)))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(blocks(response)[0]["share"], "off")
        let missing = await router.handle(AutomationRequest(operation: .proxy))
        XCTAssertEqual(missing.exitCode, AutomationExitCode.usage)
    }
}

private final class ExitIPBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: String?
    private var _delay: TimeInterval = 0
    var value: String? {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); _value = newValue; lock.unlock() }
    }
    /// Seconds the probe takes — lets a test overlap two checks.
    var delay: TimeInterval {
        get { lock.lock(); defer { lock.unlock() }; return _delay }
        set { lock.lock(); _delay = newValue; lock.unlock() }
    }
    func probe() -> String? {
        let pause = delay
        if pause > 0 { Thread.sleep(forTimeInterval: pause) }
        return value
    }
}
