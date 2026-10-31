import XCTest
@testable import DevDeck

private final class HeldDisk: VMDiskProbing, @unchecked Sendable {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func sample() -> VMDiskInfo? {
        entered.fulfill(); _ = release.wait(timeout: .now() + 3)
        return .init(usedBytes: 90, totalBytes: 100)
    }
}

@MainActor final class MonitoringRefreshRaceTests: XCTestCase {
    func testDisabledDiskCannotPublishAfterAwait() async {
        let entered = expectation(description: "disk held")
        let probe = HeldDisk(entered)
        var enabled = true
        let manager = ProcessManager(runner: FakeCommandRunner(), vmMonitoringEnabled: { enabled }, diskProbe: probe)
        let task = Task { await manager.refreshVMDisk() }
        await fulfillment(of: [entered], timeout: 1)
        enabled = false; probe.release.signal(); await task.value
        XCTAssertNil(manager.cachedVMDisk)
    }

    func testClosingLastReaderCancelsBeforeHeavyProbe() async {
        let entered = expectation(description: "light held")
        var release: CheckedContinuation<Void, Never>?
        var heavy = 0
        let model = DeckMonitoringModel(interval: .milliseconds(10), refresh: {
            await withCheckedContinuation { release = $0; entered.fulfill() }
        }, refreshHeavy: { heavy += 1 })
        let reader = UUID(); model.begin(reader)
        await fulfillment(of: [entered], timeout: 1)
        model.end(reader); release?.resume()
        try? await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(heavy, 0, "closing must not start another expensive probe")
    }
}

private final class HeldRead: @unchecked Sendable {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func wait() { entered.fulfill(); _ = release.wait(timeout: .now() + 3) }
}
private struct HeldVM: VMMemoryProbing {
    let hold: HeldRead
    func sample() -> VMMemoryInfo? { hold.wait(); return .init(usedBytes: 50, limitBytes: 100) }
}
private struct HeldMK: MinikubeProbing {
    let hold: HeldRead
    func sample() -> MinikubeSample? { hold.wait(); return .init(anonBytes: 50, limitBytes: 100, rustcCount: 0, rustcRSSBytes: 0) }
}
private struct HeldHost: HostMetricsProbing {
    let hold: HeldRead
    func sample(buildPID: Int32?) -> HostMetricsSample {
        hold.wait(); return .init(pressure: .normal, swapInsPages: 0, swapOutsPages: 0,
                                 compressorPages: 0, totalBytes: 100, buildFootprintBytes: 0)
    }
}
private struct HeldCluster: ClusterHealthProbing {
    let hold: HeldRead
    func sample() -> ClusterHealth { hold.wait(); return .init(level: .healthy, detail: "fixture") }
}

extension MonitoringRefreshRaceTests {
    func testEverySharedRefreshRejectsDisabledCancelledAndReplacedEngineResults() async {
        for kind in 0..<5 {
            for invalidation in 0..<3 {
                let entered = expectation(description: "held \(kind)/\(invalidation)")
                let hold = HeldRead(entered)
                let disk = HeldDisk(entered)
                var enabled = true
                let manager = ProcessManager(runner: FakeCommandRunner(), vmProbe: HeldVM(hold: hold),
                    vmMonitoringEnabled: { enabled }, minikubeProbe: HeldMK(hold: hold),
                    minikubeMonitoringEnabled: { enabled }, hostProbe: HeldHost(hold: hold),
                    hostMonitoringEnabled: { enabled }, clusterProbe: HeldCluster(hold: hold),
                    clusterHealthEnabled: { enabled }, diskProbe: disk)
                let task = Task {
                    switch kind {
                    case 0: await manager.refreshVMSample()
                    case 1: await manager.refreshMinikubeSample()
                    case 2: await manager.refreshHostSample()
                    case 3: await manager.refreshClusterHealth()
                    default: await manager.refreshVMDisk()
                    }
                }
                await fulfillment(of: [entered], timeout: 1)
                switch invalidation {
                case 0: enabled = false
                case 1: task.cancel()
                default: manager.invalidateMonitoringSamples()
                }
                hold.release.signal(); disk.release.signal(); await task.value
                XCTAssertNil(manager.vmMemorySample())
                XCTAssertNil(manager.minikubeSample())
                XCTAssertNil(manager.cachedHostSample)
                XCTAssertNil(manager.cachedClusterHealth)
                XCTAssertNil(manager.cachedVMDisk)
            }
        }
    }
}


private final class HandoffRead: @unchecked Sendable {
    let entered: XCTestExpectation
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var calls = 0, live = 0
    private(set) var overlap = false
    init(_ entered: XCTestExpectation) { self.entered = entered }
    func sample() -> UInt64 {
        lock.lock(); calls += 1; live += 1
        let call = calls
        if live > 1 { overlap = true }
        lock.unlock()
        if call == 1 { entered.fulfill(); _ = release.wait(timeout: .now() + 5) }
        lock.lock(); live -= 1; lock.unlock()
        return call == 1 ? 11 : 22
    }
}
private struct ImmediateHandoffVM: VMMemoryProbing {
    func sample() -> VMMemoryInfo? { .init(usedBytes: 1, limitBytes: 100) }
}
private struct HandoffVM: VMMemoryProbing {
    let read: HandoffRead
    func sample() -> VMMemoryInfo? { .init(usedBytes: read.sample(), limitBytes: 100) }
}
private struct HandoffDisk: VMDiskProbing {
    let read: HandoffRead
    func sample() -> VMDiskInfo? { .init(usedBytes: read.sample(), totalBytes: 100) }
}
private struct HandoffMK: MinikubeProbing {
    let read: HandoffRead
    func sample() -> MinikubeSample? { .init(anonBytes: read.sample(), limitBytes: 100, rustcCount: 0, rustcRSSBytes: 0) }
}
@MainActor extension MonitoringRefreshRaceTests {
    func testRunToUIHandoffWaitsForCleanupAndPublishesFreshValue() async {
        for kind in 0..<3 {
            let entered = expectation(description: "run probe held \(kind)")
            let read = HandoffRead(entered)
            let runner = FakeCommandRunner()
            let manager = ProcessManager(runner: runner, vmProbe: kind == 1 ? ImmediateHandoffVM() : HandoffVM(read: read),
                vmMonitoringEnabled: { kind != 2 }, minikubeProbe: HandoffMK(read: read),
                minikubeMonitoringEnabled: { kind == 2 }, hostMonitoringEnabled: { false },
                diskProbe: HandoffDisk(read: read))
            let command = Command(id: UUID(), name: "fixture", command: "fake")
            runner.eagerScripts[command.id] = [.started(pid: 42)]
            manager.run(command)
            await fulfillment(of: [entered], timeout: 1)
            runner.controller(for: command.id)?.terminate(0)
            while manager.states[command.id] == .running { await Task.yield() }
            let ui = Task {
                switch kind {
                case 0: await manager.refreshVMSample()
                case 1: await manager.refreshVMDisk()
                default: await manager.refreshMinikubeSample()
                }
            }
            for _ in 0..<30 { await Task.yield() }
            read.release.signal()
            await ui.value
            for _ in 0..<30 { await Task.yield() }
            XCTAssertFalse(read.overlap, "UI must wait through run probe cleanup")
            switch kind {
            case 0: XCTAssertEqual(manager.vmMemorySample()?.usedBytes, 22)
            case 1: XCTAssertEqual(manager.cachedVMDisk?.usedBytes, 22)
            default: XCTAssertEqual(manager.minikubeSample()?.anonBytes, 22)
            }
        }
    }
}
