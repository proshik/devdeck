import XCTest
import IOKit.ps
@testable import DevDeck

private struct ReviewVM: VMMemoryProbing {
    func sample() -> VMMemoryInfo? { .init(usedBytes: 7, limitBytes: 10) }
}
private final class ReviewDisk: VMDiskProbing, @unchecked Sendable {
    let sampled: XCTestExpectation
    init(_ sampled: XCTestExpectation) { self.sampled = sampled }
    func sample() -> VMDiskInfo? { sampled.fulfill(); return .init(usedBytes: 4, totalBytes: 10) }
}
@MainActor final class MonitoringReviewTests: XCTestCase {
    func testEnablingGateStartsSamplerForAlreadyActiveCommand() async throws {
        let runner = FakeCommandRunner()
        var enabled = false
        let disk = expectation(description: "disk sampled after enable")
        let manager = ProcessManager(runner: runner, vmProbe: ReviewVM(), vmMonitoringEnabled: { enabled },
            hostMonitoringEnabled: { false }, diskProbe: ReviewDisk(disk))
        let command = Command(id: UUID(), name: "fixture", command: "fake")
        runner.eagerScripts[command.id] = [.started(pid: 42)]
        manager.run(command)
        for _ in 0..<30 { await Task.yield() }
        enabled = true
        manager.invalidateMonitoringSamples()
        await fulfillment(of: [disk], timeout: 1)
        XCTAssertEqual(manager.vmMemorySample()?.usedBytes, 7)
        runner.controller(for: command.id)?.terminate(0)
    }
}

private final class ReviewChild: MonitoringChild {
    var finishedSuccessfully: Bool?
    var terminated = 0
    var output = Data("fixture".utf8)
    func readAvailable() -> Data { defer { output.removeAll() }; return output }
    func terminateGroupAndReap() { terminated += 1 }
}

extension MonitoringReviewTests {
    func testDeadlineAndCancellationAlwaysTerminateOwnedChild() {
        for cancel in [false, true] {
            let child = ReviewChild()
            var clock = 0.0
            let result = MonitoringCommand.collect(child, cancelled: { cancel && clock >= 1 },
                now: { clock }, wait: { clock += 1 }, timeout: 2)
            XCTAssertNil(result)
            XCTAssertEqual(child.terminated, 1)
            XCTAssertEqual(clock, cancel ? 1 : 2)
        }
        let child = ReviewChild(); child.finishedSuccessfully = true
        XCTAssertEqual(MonitoringCommand.collect(child, cancelled: { false }), "fixture")
        XCTAssertEqual(child.terminated, 1, "even successful parents must not leave descendants")
    }

    func testCancelledWorkDoesNotPoisonSharedRevisionScope() async {
        let parent = MonitoringCancellation()
        let entered = expectation(description: "entered")
        let finished = expectation(description: "child cleanup")
        let work = Task {
            await MonitoringProbeWork.perform(parent) {
                entered.fulfill()
                let child = ReviewChild()
                let result = MonitoringCommand.collect(child,
                    cancelled: { MonitoringProbeWork.cancellation?.isCancelled == true },
                    wait: { sched_yield() }, timeout: 1)
                XCTAssertNil(result); XCTAssertEqual(child.terminated, 1); finished.fulfill()
            }
        }
        await fulfillment(of: [entered], timeout: 1)
        work.cancel()
        await fulfillment(of: [finished], timeout: 1)
        await work.value
        XCTAssertFalse(parent.isCancelled)
        let fresh = await MonitoringProbeWork.perform(parent) { MonitoringProbeWork.cancellation?.isCancelled }
        XCTAssertEqual(fresh, false)
    }

    func testPublicBatteryConditionHasPriorityAndDoesNotUseUPS() {
        XCTAssertEqual(PowerDetails.publicHealth([
            [kIOPSTypeKey: "UPS", kIOPSBatteryHealthConditionKey: "wrong source"],
            [kIOPSTypeKey: kIOPSInternalBatteryType, kIOPSBatteryHealthKey: kIOPSGoodValue,
             kIOPSBatteryHealthConditionKey: kIOPSCheckBatteryValue]
        ]), "Check Battery")
        XCTAssertEqual(PowerDetails.publicHealth([[kIOPSTypeKey: kIOPSInternalBatteryType,
                                                   kIOPSBatteryHealthKey: kIOPSGoodValue]]), "Good")
        XCTAssertEqual(PowerDetails.publicHealth([[kIOPSTypeKey: kIOPSInternalBatteryType,
            kIOPSBatteryHealthConditionKey: "", kIOPSBatteryHealthKey: "Check Battery"]]), "Check Battery")
        XCTAssertNil(PowerDetails.publicHealth([]))
        XCTAssertNil(PowerDetails.publicHealth([[kIOPSTypeKey: kIOPSInternalBatteryType]]))
    }

    func testSlowHeavyWorkCannotBlockLightAndOldGenerationCannotPublish() async {
        let heavyStarted = expectation(description: "held heavy")
        let lightAdvanced = expectation(description: "light continued")
        let freshHeavy = expectation(description: "fresh heavy")
        var release: CheckedContinuation<Void, Never>?
        var heavyCount = 0, lightCount = 0
        var clock = Date(timeIntervalSince1970: 100)
        let model = DeckMonitoringModel(now: { clock }, waitForNext: { _ in await Task.yield() }, heavySample: {
            heavyCount += 1
            let value = heavyCount == 1 ? UInt64(111) : UInt64(222)
            if heavyCount == 1 { await withCheckedContinuation { release = $0; heavyStarted.fulfill() } }
            else { freshHeavy.fulfill() }
            return .init(containers: .init(date: .now, value: .init(engine: .colima, engineName: "fixture",
                running: true, vm: .init(usedBytes: value, limitBytes: 1000), minikube: nil, disk: nil, cluster: nil)))
        }, sample: { _ in
            lightCount += 1
            if lightCount == 4 { lightAdvanced.fulfill() }
            return .init(mac: .init(date: .now, value: .init(sample: .init(loadAverage: Double(lightCount)),
                 cpuBusyPercent: nil, swapInBytesPerSecond: nil, swapOutBytesPerSecond: nil)))
        })
        let reader = UUID(); model.begin(reader)
        await fulfillment(of: [heavyStarted, lightAdvanced], timeout: 1)
        XCTAssertNotNil(model.snapshot.mac)
        XCTAssertNil(model.snapshot.containers)
        XCTAssertEqual(heavyCount, 1)
        model.configure(.init(engine: .dockerDesktop))
        clock = clock.addingTimeInterval(16)
        release?.resume()
        await fulfillment(of: [freshHeavy], timeout: 1)
        for _ in 0..<20 { await Task.yield() }
        model.end(reader)
        XCTAssertEqual(model.snapshot.containers?.value.vm?.usedBytes, 222)
        XCTAssertFalse(model.history.contains { $0.vmMemory == 11.1 })
    }

    func testCompactMemoryStatusKeepsTimestampWhenDisabledOrSuspended() async {
        let ready = expectation(description: "memory")
        let date = Date(timeIntervalSince1970: 100)
        let model = DeckMonitoringModel(waitForNext: { _ in await Task.yield() }, sample: { _ in
            .init(mac: .init(date: date, value: .init(sample: .init(memory: .init(usedBytes: 4, totalBytes: 10)),
                cpuBusyPercent: nil, swapInBytesPerSecond: nil, swapOutBytesPerSecond: nil)))
        })
        let reader = UUID(); model.begin(reader)
        for _ in 0..<30 { await Task.yield() }
        ready.fulfill(); await fulfillment(of: [ready], timeout: 1)
        XCTAssertNotNil(model.snapshot.mac)
        let language = LocalizationManager.shared.language
        defer { LocalizationManager.shared.language = language; model.end(reader) }
        for language in AppLanguage.allCases {
            LocalizationManager.shared.language = language
            model.configure(.init(settings: .init(enabled: false)))
            XCTAssertTrue(model.memoryStatus?.contains(L10n.monitoringLast) == true)
            XCTAssertTrue(model.memoryStatus?.contains(date.formatted(date: .omitted, time: .standard)) == true)
            model.configure(.init()); model.setSuspended(true)
            XCTAssertTrue(model.memoryStatus?.contains(L10n.deckCollectionOff) == true)
            model.setSuspended(false)
        }
    }

    func testPopoverThemeTracksRuntimeChangesAndRestoresSystem() async {
        let manager = AppearanceManager()
        let original = manager.appearance
        defer { manager.appearance = original }
        let popover = NSPopover()
        let binding = PopoverAppearanceBinding(popover, manager: manager)
        for (choice, expected) in [(AppAppearance.light, NSAppearance.Name.aqua), (.dark, .darkAqua)] {
            manager.appearance = choice
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(popover.appearance?.name, expected)
        }
        manager.appearance = .system
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNil(popover.appearance)
        withExtendedLifetime(binding) {}
    }
}

private final class ReviewDiskSequence: VMDiskProbing, @unchecked Sendable {
    let failed: XCTestExpectation
    private let lock = NSLock()
    private var count = 0
    init(_ failed: XCTestExpectation) { self.failed = failed }
    func sample() -> VMDiskInfo? {
        lock.lock(); count += 1; let call = count; lock.unlock()
        if call == 1 { return .init(usedBytes: 8, totalBytes: 10) }
        if call == 2 { failed.fulfill() }
        return nil
    }
}
extension MonitoringReviewTests {
    func testActiveRunDiskFailureClearsValueAndMeasurementDate() async {
        let runner = FakeCommandRunner()
        let first = expectation(description: "first run iteration finished")
        let failed = expectation(description: "disk failure")
        var release: CheckedContinuation<Void, Never>?
        var waits = 0
        let manager = ProcessManager(runner: runner, vmProbe: ReviewVM(),
            hostMonitoringEnabled: { false }, diskProbe: ReviewDiskSequence(failed))
        manager.monitoringSamplerWait = { _ in
            waits += 1
            if waits == 1 { await withCheckedContinuation { release = $0; first.fulfill() } }
            else { await Task.yield() }
        }
        let command = Command(id: UUID(), name: "fixture", command: "fake")
        runner.eagerScripts[command.id] = [.started(pid: 42)]
        manager.run(command)
        await fulfillment(of: [first], timeout: 1)
        XCTAssertEqual(manager.cachedVMDisk?.usedBytes, 8)
        XCTAssertNotNil(manager.cachedVMDiskDate)
        release?.resume()
        await fulfillment(of: [failed], timeout: 1)
        for _ in 0..<30 { await Task.yield() }
        XCTAssertNil(manager.cachedVMDisk)
        XCTAssertNil(manager.cachedVMDiskDate, "failed value must not acquire a fresh timestamp")
        runner.controller(for: command.id)?.terminate(0)
    }
}

extension MonitoringReviewTests {
    func testHeavyCancellationReleasesSlotForCloseMasterAndEngineChange() async {
        for change in 0...2 {
            let entered = expectation(description: "heavy entered \(change)")
            let cleaned = expectation(description: "heavy cancelled \(change)")
            let fresh = expectation(description: "heavy restarted \(change)")
            var release: CheckedContinuation<Void, Never>?
            var calls = 0
            var clock = Date(timeIntervalSince1970: 100)
            let model = DeckMonitoringModel(now: { clock }, waitForNext: { _ in await Task.yield() }, heavySample: {
                calls += 1
                let call = calls
                if call == 1 {
                    await withTaskCancellationHandler {
                        await withCheckedContinuation { release = $0; entered.fulfill() }
                    } onCancel: {
                        Task { @MainActor in release?.resume(); release = nil; cleaned.fulfill() }
                    }
                } else if call == 2 { fresh.fulfill() }
                return .init(containers: .init(date: .now, value: .init(engine: .colima, engineName: "fixture",
                    running: true, vm: .init(usedBytes: UInt64(call), limitBytes: 10), minikube: nil, disk: nil, cluster: nil)))
            })
            let reader = UUID(); model.begin(reader)
            await fulfillment(of: [entered], timeout: 1)
            clock = clock.addingTimeInterval(15)
            if change == 0 { model.end(reader) }
            if change == 1 { model.configure(.init(settings: .init(enabled: false))) }
            if change == 2 { model.configure(.init(engine: .dockerDesktop)) }
            await fulfillment(of: [cleaned], timeout: 1)
            if change == 0 { model.begin(reader) }
            if change == 1 { model.configure(.init()) }
            await fulfillment(of: [fresh], timeout: 1)
            for _ in 0..<20 { await Task.yield() }
            model.end(reader)
            XCTAssertEqual(model.snapshot.containers?.value.vm?.usedBytes, 2)
            XCTAssertFalse(model.history.contains { $0.vmMemory == 10 })
        }
    }
}


extension MonitoringReviewTests {
    func testProductionHeavyCadenceRetainsStartAcrossCloseAndIntervalChange() async {
        for close in [true, false] {
            var clock = Date(timeIntervalSince1970: 100)
            var calls = 0, ticks = 0
            var release: CheckedContinuation<Void, Never>?
            let entered = expectation(description: "production heavy held")
            let fresh = expectation(description: "heavy at fifteen seconds")
            let model = DeckMonitoringModel(now: { clock }, waitForNext: { _ in await Task.yield() }, heavySample: {
                calls += 1
                if calls == 1 { await withCheckedContinuation { release = $0; entered.fulfill() } }
                if calls == 2 { fresh.fulfill() }
                return .init()
            }, sample: { _ in ticks += 1; return .init() })
            let reader = UUID(); model.begin(reader)
            await fulfillment(of: [entered], timeout: 1)
            if close { model.end(reader); model.begin(reader) }
            else { model.configure(.init(settings: .init(intervalSeconds: 5))) }
            clock = Date(timeIntervalSince1970: 114)
            release?.resume()
            let before = ticks
            while ticks < before + 10 { await Task.yield() }
            XCTAssertEqual(calls, 1, "cancelled production work retains its start time")
            clock = Date(timeIntervalSince1970: 115)
            await fulfillment(of: [fresh], timeout: 1)
            model.end(reader)
        }
    }
}
