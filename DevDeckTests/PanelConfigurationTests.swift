import XCTest
@testable import DevDeck

@MainActor
final class PanelConfigurationTests: XCTestCase {
    func testLegacyConfigKeepsCommandsAndSettingsAndAddsStandardLayout() throws {
        let data = Data(#"{"commands":[{"name":"serve","command":"echo ok"}],"settings":{"hostMemoryMonitoring":false,"proxyShareEnabled":true}}"#.utf8)
        let config = try ConfigCodec.decode(data)
        XCTAssertEqual(config.commands.map(\.name), ["serve"])
        XCTAssertFalse(config.settings.hostMemoryMonitoring)
        XCTAssertTrue(config.settings.proxyShareEnabled)
        XCTAssertEqual(config.panel.sections.map(\.id), ["environment", "monitoring", "displays"])
        XCTAssertEqual(config.panel.sections[0].modules.map(\.id), ["commands", "daemons", "chains", "portForwards", "proxy", "agentTabs"])
        XCTAssertEqual(try ConfigCodec.decode(ConfigCodec.encode(config)), config)
    }

    func testUnknownAndDuplicateIDsCannotDuplicateControlsOrResetPlacement() throws {
        let data = Data(#"{"panel":{"sections":[{"id":"displays","modules":[{"id":"agentTabs","isVisible":false},{"id":"mac"},{"id":"future-module"},{"id":"mac"}]},{"id":"future-section"},{"id":"monitoring","isVisible":false},{"id":"displays","modules":[{"id":"agentTabs"}]}],"initialSection":"unknown","lastSection":"unknown"}}"#.utf8)
        let panel = try ConfigCodec.decode(data).panel
        XCTAssertEqual(panel.sections.map(\.id), ["displays", "monitoring", "environment"])
        XCTAssertEqual(panel.sections[0].modules.map(\.id), ["agentTabs", "mac", "awake"])
        XCTAssertFalse(panel.sections[0].modules[0].isVisible)
        XCTAssertFalse(panel.sections[1].isVisible)
        XCTAssertEqual(panel.sections[1].modules.map(\.id), ["containers", "energy"])
        XCTAssertEqual(panel.sections.flatMap(\.modules).count, 10)
        XCTAssertEqual(panel.initialSection, "environment")
        XCTAssertNil(panel.lastSection)
        XCTAssertEqual(panel.normalized(), panel, "normalization must be stable on subsequent saves")
    }

    func testDragPlacementAndKeyboardMovesKeepVisibilityAndSurviveReload() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let store = CommandStore(configURL: url)
        let command = Command(id: UUID(), name: "tunnel", command: "echo ok", isDaemon: true, port: 8123)
        let original = Config(commands: [command], settings: Settings(proxyShareEnabled: true, claudeTabsRestore: true))
        try store.save(original)
        store.updatePanel {
            $0.setModuleVisible(.proxy, false)
            $0.moveModule(.proxy, to: .displays, before: .awake)
            $0.moveModule(.agentTabs, to: .displays, before: .proxy)
            $0.shiftModule(.proxy, by: -1)
            $0.moveSection(.displays, before: .environment)
            $0.lastSection = "displays"
        }
        let restarted = CommandStore(configURL: url)
        restarted.reload()
        XCTAssertEqual(restarted.config.panel.sections[0].modules.map(\.id), ["proxy", "agentTabs", "awake"])
        XCTAssertFalse(restarted.config.panel.isShown(.proxy))
        XCTAssertEqual(restarted.config.panel.openingSection, .displays)
        XCTAssertEqual(restarted.config.commands, original.commands)
        XCTAssertEqual(restarted.config.settings, original.settings, "hiding must not disable the proxy or agent capture")
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        restarted.updatePanel { $0.sections = PanelConfiguration.standard.sections }
        XCTAssertEqual(restarted.config.panel.sections.map(\.id), ["environment", "monitoring", "displays"])
        XCTAssertTrue(restarted.config.panel.isShown(.proxy))
        XCTAssertEqual(restarted.config.panel.lastSection, "displays", "resetting placement should not reset panel behavior")
    }

    func testSelectionFollowsVisibleOrderAndCanHaveNoSection() {
        var panel = PanelConfiguration.standard
        panel.lastSection = "displays"
        panel.initialSection = "monitoring"
        XCTAssertEqual(panel.openingSection, .displays)
        panel.rememberLastSection = false
        XCTAssertEqual(panel.openingSection, .monitoring)
        panel.sections[1].isVisible = false
        XCTAssertEqual(panel.openingSection, .environment)
        panel.moveSection(.displays, before: .environment)
        XCTAssertEqual(panel.openingSection, .displays)
        for module in PanelModuleID.allCases { panel.setModuleVisible(module, false) }
        XCTAssertNil(panel.openingSection)
        XCTAssertTrue(panel.visibleSections.isEmpty)
        panel.showMemoryInEnvironment = true
        XCTAssertEqual(panel.visibleSections, [.environment])
        panel.setSectionVisible(.environment, false)
        XCTAssertNil(panel.openingSection, "an explicitly hidden section stays hidden even with the optional memory row")
        panel.revealModule(.proxy)
        XCTAssertTrue(panel.isShown(.proxy), "Show in panel must also reveal a hidden parent section")
    }

    func testMovingToEndAndDroppingOntoSelfDoesNotLoseModules() {
        var panel = PanelConfiguration.standard
        panel.moveModule(.commands, to: .environment, before: .commands)
        XCTAssertEqual(panel.sections[0].modules.first?.id, "commands")
        panel.moveModule(.commands, to: .environment)
        XCTAssertEqual(panel.sections[0].modules.last?.id, "commands")
        panel.shiftModule(.commands, by: 1)
        XCTAssertEqual(panel.sections[0].modules.last?.id, "commands")
        panel.moveSection(.environment, after: .displays)
        XCTAssertEqual(panel.sections.map(\.id), ["monitoring", "displays", "environment"])
    }

    func testCustomTabsAndModuleCatalogueSurviveReloadWithoutRestoringRemovedItems() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let store = CommandStore(configURL: url)
        let command = Command(id: UUID(), name: "serve", command: "echo ok")
        let original = Config(commands: [command], settings: Settings(proxyShareEnabled: true))
        try store.save(original)
        var custom: PanelSection!
        store.updatePanel {
            $0.removeModule(.proxy)
            custom = $0.addSection(name: "Services", icon: "network")
            $0.moveModule(.proxy, to: custom)
            $0.moveModule(.commands, to: custom, before: .proxy)
            $0.renameSection(custom, name: " My workspace ", icon: "star")
            $0.moveSection(custom, before: .environment)
            $0.removeSection(.monitoring)
            $0.initialSection = custom.rawValue
            $0.lastSection = custom.rawValue
        }
        let restarted = CommandStore(configURL: url)
        restarted.reload()
        let panel = restarted.config.panel
        XCTAssertEqual(panel.sections.first?.id, custom.rawValue)
        XCTAssertEqual(panel.sections.first?.title, "My workspace")
        XCTAssertEqual(panel.sections.first?.symbol, "star")
        XCTAssertEqual(panel.sections.first?.modules.map(\.id), ["commands", "proxy"])
        XCTAssertFalse(panel.sections.contains { $0.id == "monitoring" })
        XCTAssertEqual(panel.availableModules, [.mac, .containers, .energy])
        XCTAssertEqual(panel.openingSection, custom)
        XCTAssertEqual(panel.normalized(), panel)
        XCTAssertEqual(restarted.config.commands, original.commands)
        XCTAssertEqual(restarted.config.settings, original.settings)
        restarted.updatePanel { $0.removeSection(custom) }
        restarted.reload()
        XCTAssertTrue(restarted.config.panel.availableModules.contains(.proxy))
        XCTAssertFalse(restarted.config.panel.sections.contains { $0.id == custom.rawValue })
        XCTAssertNil(restarted.config.panel.lastSection)
    }

    func testRemovingAllTabsStaysEmptyAndCanBeRebuiltFromCatalogueOrReset() throws {
        var panel = PanelConfiguration.standard
        for section in PanelSection.allCases { panel.removeSection(section) }
        panel = try ConfigCodec.decode(ConfigCodec.encode(Config(panel: panel))).panel
        XCTAssertTrue(panel.sections.isEmpty)
        XCTAssertEqual(panel.availableModules, PanelModuleID.allCases)
        XCTAssertNil(panel.openingSection)
        let custom = panel.addSection(name: "Only tools")
        panel.moveModule(.awake, to: custom)
        panel = panel.normalized()
        XCTAssertEqual(panel.sections.map(\.id), [custom.rawValue])
        XCTAssertEqual(panel.visibleSections, [custom])
        XCTAssertEqual(panel.openingSection, custom)
        XCTAssertFalse(panel.availableModules.contains(.awake))
        XCTAssertEqual(panel.availableModules.count, 9)
        let previous = panel
        panel.moveModule(.proxy, to: .environment)
        XCTAssertEqual(panel, previous, "a stale drop target must not resurrect a removed tab or consume a catalogue item")
        panel.rememberLastSection = false
        panel.showMemoryInEnvironment = true
        panel.restoreStandardLayout()
        panel = panel.normalized()
        XCTAssertEqual(panel.sections, PanelConfiguration.standard.sections)
        XCTAssertTrue(panel.availableModules.isEmpty)
        XCTAssertTrue(panel.removedModuleIDs.isEmpty)
        XCTAssertTrue(panel.removedSectionIDs.isEmpty)
        XCTAssertFalse(panel.rememberLastSection)
        XCTAssertTrue(panel.showMemoryInEnvironment)
    }

    func testExternalLayoutEditIsAcceptedAndMalformedEditKeepsLastValidLayout() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("config.json")
        let store = CommandStore(configURL: url)
        try store.save(.empty)
        var external = Config.empty
        external.panel.moveModule(.awake, to: .environment, before: .commands)
        external.panel.showMemoryInEnvironment = true
        try ConfigCodec.encode(external).write(to: url, options: .atomic)
        XCTAssertTrue(store.reload())
        XCTAssertEqual(store.config.panel.sections[0].modules.first?.id, "awake")
        XCTAssertTrue(store.config.panel.showMemoryInEnvironment)
        let valid = store.config
        try Data(#"{"panel":{"sections":"not-an-array"}}"#.utf8).write(to: url, options: .atomic)
        XCTAssertFalse(store.reload())
        XCTAssertNotNil(store.error)
        XCTAssertEqual(store.config, valid)
    }

    func testHiddenSummaryUsesLiveStatesAndIgnoresFinishedCommands() {
        let port = Command(id: UUID(), name: "port", command: "echo ok", isDaemon: true, port: 8123)
        let daemon = Command(id: UUID(), name: "daemon", command: "echo ok", isDaemon: true)
        let finished = Command(id: UUID(), name: "finished", command: "echo ok")
        let chain = Chain(id: UUID(), name: "chain", commandIDs: [])
        let active = PanelActivity.activeModules(commands: [port, daemon, finished],
            states: [port.id: .daemonRunning, daemon.id: .running, finished.id: .succeeded],
            chains: [chain], chainStates: [chain.id: .idle], proxyActive: true, agentCaptureEnabled: false, awakeActive: true)
        XCTAssertEqual(active, [.daemons, .portForwards, .proxy, .awake])
        var panel = PanelConfiguration.standard
        panel.setModuleVisible(.portForwards, false)
        panel.sections[2].isVisible = false
        XCTAssertEqual(active.filter { !panel.isShown($0) }, [.portForwards, .awake])
        panel.moveModule(.portForwards, to: .monitoring)
        XCTAssertEqual(active.filter { !panel.isShown($0) }, [.portForwards, .awake])
    }

    func testHidingMovingAndRemovingRunningPortAndProxyDoesNotStopOrRestartThem() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommandStore(configURL: directory.appendingPathComponent("config.json"))
        let port = Command(id: UUID(), name: "port", command: "echo ok", isDaemon: true, port: 8123)
        let share = Command(id: ProxyShare.daemonID, name: "proxy", command: "echo ok", isDaemon: true)
        try store.save(Config(commands: [port], settings: Settings(proxyShareEnabled: true)))
        let originalSettings = store.config.settings
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner, notifier: FakeNotifier(), portInspector: FakePortInspector())
        defer { manager.stop(port.id); manager.stop(share.id) }
        manager.run(port)
        await yieldUntil { runner.controller(for: port.id) != nil }
        try XCTUnwrap(runner.controller(for: port.id)).started(pid: 111)
        manager.run(share)
        try XCTUnwrap(runner.controller(for: share.id)).started(pid: 222)
        await yieldUntil { manager.states[port.id] == .daemonRunning && manager.states[share.id] == .daemonRunning }
        store.updatePanel {
            $0.setModuleVisible(.portForwards, false)
            $0.setModuleVisible(.proxy, false)
            $0.moveModule(.portForwards, to: .displays)
            $0.moveModule(.proxy, to: .monitoring)
        }
        let hidden = PanelActivity.activeModules(commands: store.config.commands, states: manager.states,
            chains: [], chainStates: [:], proxyActive: manager.states[share.id] == .daemonRunning,
            agentCaptureEnabled: false, awakeActive: false).filter { !store.config.panel.isShown($0) }
        XCTAssertEqual(hidden, [.portForwards, .proxy])
        XCTAssertEqual(manager.states[port.id], .daemonRunning)
        XCTAssertEqual(manager.states[share.id], .daemonRunning)
        XCTAssertEqual(runner.controller(for: port.id)?.stopCount, 0)
        XCTAssertEqual(runner.controller(for: share.id)?.stopCount, 0)
        store.updatePanel {
            $0.removeSection(.displays)
            $0.removeModule(.proxy)
        }
        XCTAssertTrue(store.config.panel.availableModules.contains(.portForwards))
        XCTAssertTrue(store.config.panel.availableModules.contains(.proxy))
        XCTAssertEqual(manager.states[port.id], .daemonRunning)
        XCTAssertEqual(manager.states[share.id], .daemonRunning)
        XCTAssertEqual(runner.controller(for: port.id)?.stopCount, 0)
        XCTAssertEqual(runner.controller(for: share.id)?.stopCount, 0)
        store.updatePanel { $0.sections = PanelConfiguration.standard.sections }
        XCTAssertEqual(runner.startedCommandIDs, [port.id, share.id])
        XCTAssertEqual(store.config.settings, originalSettings)
    }
}
