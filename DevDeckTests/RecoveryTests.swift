import XCTest
@testable import DevDeck

@MainActor
final class RecoveryTests: XCTestCase {
    private let boot = 1_790_000_000
    private let start = Date(timeIntervalSince1970: 1_790_001_000)

    private func run(boot: Int? = nil, clean: Bool = false, survived: Bool = false) -> RecoveryRunRecord {
        RecoveryRunRecord(bootTime: boot ?? self.boot, launchedAt: start, cleanExit: clean, survivedEarlyWindow: survived)
    }

    private func evaluate(_ state: RecoveryState, markers: Set<RecoveryOperation> = [], build: String = "100")
        -> (state: RecoveryState, newlySuspended: [RecoveryModule]) {
        RecoveryPolicy.evaluateLaunch(state, markers: markers, bootTime: boot, installedBuild: build, now: start)
    }

    // MARK: policy

    func testFirstLaunchRecordsAnUncleanRun() {
        let result = evaluate(RecoveryState())
        XCTAssertEqual(result.newlySuspended, [])
        XCTAssertEqual(result.state.lastRun, run())
        XCTAssertTrue(result.state.suspended.isEmpty)
    }

    func testThreeEarlyCrashesInARowSuspendEveryNewModule() {
        var state = RecoveryState(); state.lastRun = run()
        state = evaluate(state).state
        XCTAssertEqual(state.earlyUncleanExits, 1)
        state = evaluate(state).state
        XCTAssertEqual(state.earlyUncleanExits, 2)
        let third = evaluate(state)
        XCTAssertEqual(Set(third.newlySuspended), Set(RecoveryModule.allCases))
        XCTAssertEqual(third.state.suspended[.clipboard]?.reason, .repeatedCrashes)
        XCTAssertEqual(third.state.earlyUncleanExits, 0, "the count starts over once modules are off")
    }

    func testCleanExitBreaksTheSeries() {
        var state = RecoveryState(); state.earlyUncleanExits = 2; state.lastRun = run(clean: true)
        XCTAssertEqual(evaluate(state).state.earlyUncleanExits, 0)
    }

    func testCrashAfterTheEarlyWindowBreaksTheSeries() {
        var state = RecoveryState(); state.earlyUncleanExits = 2; state.lastRun = run(survived: true)
        let result = evaluate(state)
        XCTAssertEqual(result.state.earlyUncleanExits, 0)
        XCTAssertEqual(result.newlySuspended, [])
    }

    func testRebootIsNotACrashAndItsMarkersAreIgnored() {
        var state = RecoveryState(); state.earlyUncleanExits = 2; state.lastRun = run(boot: boot - 3600)
        let result = evaluate(state, markers: [.tabRestore])
        XCTAssertEqual(result.state.earlyUncleanExits, 2)
        XCTAssertEqual(result.state.strikes, [:])
        XCTAssertEqual(result.newlySuspended, [])
    }

    func testBootTimeComparesToTheSecond() {
        var state = RecoveryState(); state.lastRun = run(boot: boot)
        XCTAssertEqual(evaluate(state).state.earlyUncleanExits, 1, "the same boot is still the same boot")
    }

    func testDeathInsideAnOperationTwiceSuspendsOnlyItsModule() {
        var state = RecoveryState(); state.lastRun = run()
        let first = evaluate(state, markers: [.tabRestore])
        XCTAssertEqual(first.state.strikes[.tabRestore], 1)
        XCTAssertEqual(first.state.earlyUncleanExits, 0, "an attributed crash is not counted twice")
        XCTAssertEqual(first.newlySuspended, [])
        state = first.state
        let second = evaluate(state, markers: [.tabRestore])
        XCTAssertEqual(second.newlySuspended, [.agentTabRestore])
        XCTAssertEqual(second.state.suspended[.agentTabRestore]?.reason, .operationCrashed(.tabRestore))
        XCTAssertNil(second.state.suspended[.clipboard])
    }

    func testOperationsMapToTheirModules() {
        XCTAssertEqual(RecoveryOperation.tabRestore.module, .agentTabRestore)
        XCTAssertEqual(RecoveryOperation.heavyProbes.module, .monitoring)
        XCTAssertEqual(RecoveryOperation.displayDiscovery.module, .brightness)
        XCTAssertEqual(RecoveryOperation.updateInstall.module, .autoUpdateInstall)
    }

    func testCleanExitWithAMarkerStillStrikes() {
        // A marker left by a clean exit cannot happen (the op ended), but if it does it is not a crash.
        var state = RecoveryState(); state.lastRun = run(clean: true)
        XCTAssertEqual(evaluate(state, markers: [.heavyProbes]).state.strikes, [:])
    }

    func testInstalledPendingUpdateClearsTheMarker() {
        var state = RecoveryState(); state.lastRun = run(clean: true); state.pendingUpdateBuild = "101"
        state.strikes[.updateInstall] = 1
        let result = evaluate(state, build: "101")
        XCTAssertNil(result.state.pendingUpdateBuild)
        XCTAssertNil(result.state.strikes[.updateInstall])
    }

    func testUpdateThatDidNotInstallTwiceStopsAutomaticInstall() {
        var state = RecoveryState(); state.lastRun = run(clean: true); state.pendingUpdateBuild = "101"
        state = evaluate(state, build: "100").state
        XCTAssertEqual(state.strikes[.updateInstall], 1)
        XCTAssertNil(state.pendingUpdateBuild)
        state.lastRun = run(clean: true); state.pendingUpdateBuild = "101"
        let second = evaluate(state, build: "100")
        XCTAssertEqual(second.newlySuspended, [.autoUpdateInstall])
        XCTAssertEqual(second.state.suspended[.autoUpdateInstall]?.reason, .operationCrashed(.updateInstall))
    }

    func testAlreadySuspendedModuleIsNotReportedAgain() {
        var state = RecoveryState(); state.lastRun = run(); state.strikes[.tabRestore] = 1
        state.suspended[.agentTabRestore] = RecoverySuspension(reason: .repeatedCrashes, since: start)
        XCTAssertEqual(evaluate(state, markers: [.tabRestore]).newlySuspended, [])
    }

    // MARK: persistence

    func testStateRoundTripsAndCorruptFileIsEmpty() throws {
        var state = RecoveryState(); state.lastRun = run(); state.strikes[.heavyProbes] = 1
        state.suspended[.brightness] = RecoverySuspension(reason: .operationCrashed(.displayDiscovery), since: start)
        state.pendingUpdateBuild = "7"
        let data = try RecoveryState.encode(state)
        XCTAssertEqual(RecoveryState.decode(data), state)
        XCTAssertEqual(RecoveryState.decode(Data("{not json".utf8)), RecoveryState())
        XCTAssertEqual(RecoveryState.decode(nil), RecoveryState())
    }

    func testLiveStorageWritesAPrivateFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = FileRecoveryStorage(url: directory.appendingPathComponent("recovery.json"))
        XCTAssertNil(storage.read())
        storage.write(Data("{}".utf8))
        XCTAssertEqual(storage.read(), Data("{}".utf8))
        let mode = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("recovery.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testLiveMarkersSurviveTheProcessAndResetOnRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("recovery-markers")
        do {
            let markers = try XCTUnwrap(FileRecoveryMarkerStorage(url: url))
            XCTAssertEqual(markers.readAndReset(), 0)
            markers.write(0b101)
        }
        let next = try XCTUnwrap(FileRecoveryMarkerStorage(url: url))
        XCTAssertEqual(next.readAndReset(), 0b101)
        XCTAssertEqual(next.readAndReset(), 0)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    // MARK: model

    private func model(storage: FakeRecoveryStorage = FakeRecoveryStorage(),
                       markers: FakeRecoveryMarkerStorage = FakeRecoveryMarkerStorage(),
                       notifications: @escaping ([RecoveryModule]) -> Void = { _ in }) -> RecoveryModel {
        RecoveryModel(storage: storage, markers: markers, bootTime: { self.boot },
                      installedBuild: "100", now: { self.start }, notify: notifications)
    }

    func testLaunchReadsMarkersOfThePreviousProcessAndPersists() throws {
        let storage = FakeRecoveryStorage()
        var previous = RecoveryState(); previous.lastRun = run(); previous.strikes[.displayDiscovery] = 1
        storage.data = try RecoveryState.encode(previous)
        let markers = FakeRecoveryMarkerStorage()
        markers.stored = RecoveryOperation.displayDiscovery.bit
        var notified: [[RecoveryModule]] = []
        let recovery = model(storage: storage, markers: markers, notifications: { notified.append($0) })
        recovery.launch()
        XCTAssertTrue(recovery.isSuspended(.brightness))
        XCTAssertFalse(recovery.isSuspended(.clipboard))
        XCTAssertEqual(notified, [[.brightness]])
        XCTAssertEqual(markers.stored, 0)
        XCTAssertEqual(RecoveryState.decode(storage.data).suspended.keys.sorted(), [.brightness])
    }

    func testNoNotificationWithoutNewSuspension() {
        var notified = 0
        let recovery = model(notifications: { _ in notified += 1 })
        recovery.launch()
        XCTAssertEqual(notified, 0)
        XCTAssertFalse(recovery.hasSuspensions)
    }

    func testOperationMarkersNestAndClear() async {
        let markers = FakeRecoveryMarkerStorage()
        let recovery = model(markers: markers)
        recovery.launch()
        recovery.begin(.heavyProbes)
        recovery.begin(.heavyProbes)
        recovery.begin(.tabRestore)
        XCTAssertEqual(markers.stored, RecoveryOperation.heavyProbes.bit | RecoveryOperation.tabRestore.bit)
        recovery.end(.heavyProbes)
        XCTAssertEqual(markers.stored, RecoveryOperation.heavyProbes.bit | RecoveryOperation.tabRestore.bit)
        recovery.end(.heavyProbes)
        recovery.end(.tabRestore)
        XCTAssertEqual(markers.stored, 0)
        let value = await recovery.during(.displayDiscovery) { markers.stored }
        XCTAssertEqual(value, RecoveryOperation.displayDiscovery.bit)
        XCTAssertEqual(markers.stored, 0)
    }

    func testCompletedOperationClearsItsStrikesAndWritesOnlyWhenNeeded() throws {
        let storage = FakeRecoveryStorage()
        var previous = RecoveryState(); previous.lastRun = run(clean: true); previous.strikes[.heavyProbes] = 1
        storage.data = try RecoveryState.encode(previous)
        let recovery = model(storage: storage)
        recovery.launch()
        let writes = storage.writes
        recovery.begin(.heavyProbes); recovery.end(.heavyProbes)
        XCTAssertNil(RecoveryState.decode(storage.data).strikes[.heavyProbes])
        XCTAssertEqual(storage.writes, writes + 1)
        recovery.begin(.heavyProbes); recovery.end(.heavyProbes)
        XCTAssertEqual(storage.writes, writes + 1, "a clean cycle with nothing to clear writes nothing")
    }

    func testCleanExitAndEarlyWindowArePersisted() {
        let storage = FakeRecoveryStorage()
        let recovery = model(storage: storage)
        recovery.launch()
        recovery.markSurvivedEarlyWindow()
        XCTAssertEqual(RecoveryState.decode(storage.data).lastRun?.survivedEarlyWindow, true)
        recovery.markCleanExit()
        XCTAssertEqual(RecoveryState.decode(storage.data).lastRun?.cleanExit, true)
    }

    func testResumeOneModuleClearsItsStrikesAndCallsBack() throws {
        let storage = FakeRecoveryStorage()
        var previous = RecoveryState(); previous.lastRun = run(clean: true)
        previous.strikes[.tabRestore] = 2
        previous.suspended[.agentTabRestore] = RecoverySuspension(reason: .operationCrashed(.tabRestore), since: start)
        previous.suspended[.clipboard] = RecoverySuspension(reason: .repeatedCrashes, since: start)
        storage.data = try RecoveryState.encode(previous)
        let recovery = model(storage: storage)
        var resumed: [RecoveryModule] = []
        recovery.onResume = { resumed.append($0) }
        recovery.launch()
        recovery.resume(.agentTabRestore)
        XCTAssertEqual(resumed, [.agentTabRestore])
        XCTAssertFalse(recovery.isSuspended(.agentTabRestore))
        XCTAssertTrue(recovery.isSuspended(.clipboard))
        let saved = RecoveryState.decode(storage.data)
        XCTAssertNil(saved.strikes[.tabRestore])
        XCTAssertNil(saved.suspended[.agentTabRestore])
        recovery.resumeAll()
        XCTAssertEqual(resumed, [.agentTabRestore, .clipboard])
        XCTAssertFalse(recovery.hasSuspensions)
    }

    func testPendingUpdateIsPersisted() {
        let storage = FakeRecoveryStorage()
        let recovery = model(storage: storage)
        recovery.launch()
        recovery.updateWillInstall(build: "101")
        XCTAssertEqual(RecoveryState.decode(storage.data).pendingUpdateBuild, "101")
    }

    func testSuspensionsAreListedInModuleOrder() throws {
        let storage = FakeRecoveryStorage()
        var previous = RecoveryState(); previous.lastRun = run(clean: true)
        for module in RecoveryModule.allCases.reversed() {
            previous.suspended[module] = RecoverySuspension(reason: .repeatedCrashes, since: start)
        }
        storage.data = try RecoveryState.encode(previous)
        let recovery = model(storage: storage)
        recovery.launch()
        XCTAssertEqual(recovery.suspensions.map(\.module), RecoveryModule.allCases)
    }

    // MARK: gates

    func testHaltedMonitoringDoesNotCollectOrSampleTheNetwork() {
        let monitoring = DeckMonitoringModel(network: NetworkMonitoringModel(probe: NoInterfacesProbe(), routes: StaticNetworkRouteProbe()),
                                             interval: .milliseconds(20), refresh: {}, refreshHeavy: {})
        monitoring.begin(UUID())
        XCTAssertTrue(monitoring.isCollecting)
        monitoring.setHalted(monitoring: true, network: true)
        XCTAssertFalse(monitoring.isCollecting)
        XCTAssertTrue(monitoring.network.isHalted)
        monitoring.setHalted(monitoring: false, network: false)
        XCTAssertTrue(monitoring.isCollecting)
        XCTAssertFalse(monitoring.network.isHalted)
    }

    func testSuspendedAutomaticInstallKeepsManualChecks() {
        XCTAssertTrue(UpdateController.automaticallyDownloads(enabled: true, suspended: false))
        XCTAssertFalse(UpdateController.automaticallyDownloads(enabled: true, suspended: true))
        XCTAssertFalse(UpdateController.automaticallyDownloads(enabled: false, suspended: false))
    }
}

private struct NoInterfacesProbe: NetworkInterfaceProbing {
    func sample() -> [NetworkInterfaceSample]? { [] }
}
