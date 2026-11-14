import AppKit
import XCTest
@testable import DevDeck

@MainActor final class AppTerminationTests: XCTestCase {
    func testQuitNoDaemonsKillAndLeaveWaitForCleanupAndReplyOnlyOnce() async {
        for choice: AppTerminationCoordinator.DaemonChoice in [.kill, .leaveBackground] {
            for hasDaemons in [false, true] {
                let collector = HeldCollector()
                let model = NetworkMonitoringModel(quality: collector)
                let coordinator = AppTerminationCoordinator(network: model)
                model.runTest()
                await fulfillment(of: [collector.entered], timeout: 2)
                let daemon = UUID(), daemons = hasDaemons ? [daemon] : []
                var choices = 0, stopped: [UUID] = [], replies: [Bool] = []
                let replied = XCTestExpectation(description: "quit approved after cleanup")
                let reply: @MainActor (Bool) -> Void = { allowed in
                    XCTAssertTrue(collector.cleaned)
                    XCTAssertFalse(model.hasPendingTest)
                    replies.append(allowed); replied.fulfill()
                }
                let response = coordinator.request(daemons: daemons, choose: { choices += 1; return choice },
                    stopDaemon: { stopped.append($0) }, reply: reply)
                XCTAssertEqual(response, .terminateLater)
                await fulfillment(of: [collector.cancelled], timeout: 2)
                XCTAssertTrue(replies.isEmpty, "cancellation flag is not process cleanup")
                XCTAssertTrue(model.hasPendingTest)
                XCTAssertEqual(coordinator.request(daemons: daemons, choose: { XCTFail("duplicate dialog"); return .cancel },
                    stopDaemon: { _ in XCTFail("duplicate daemon stop") }, reply: { _ in XCTFail("duplicate reply") }), .terminateLater)
                XCTAssertEqual(choices, hasDaemons ? 1 : 0)
                XCTAssertEqual(stopped, hasDaemons && choice == .kill ? [daemon] : [])
                // MainActor is responsive while the fake collector owns cleanup.
                await Task.yield(); XCTAssertTrue(replies.isEmpty)
                model.runTest(); XCTAssertEqual(collector.calls, 1, "quit cannot start more work")
                collector.release(.failure(.cancelled))
                if response == .terminateLater { await fulfillment(of: [replied], timeout: 2) }
                await model.waitForTestCleanup()
                if response == .terminateLater {
                    XCTAssertEqual(replies, [true])
                    XCTAssertEqual(coordinator.request(daemons: daemons, choose: { XCTFail("decision already made"); return .cancel }, stopDaemon: { _ in }, reply: { _ in XCTFail("duplicate reply") }), .terminateNow)
                }
                model.stop()
            }
        }
    }
    func testCancelQuitLeavesCollectorAndDaemonsUntouchedAndAllowsLaterQuit() async {
        let collector = HeldCollector(), daemon = UUID()
        let model = NetworkMonitoringModel(quality: collector)
        let coordinator = AppTerminationCoordinator(network: model)
        model.runTest(); await fulfillment(of: [collector.entered], timeout: 2)
        XCTAssertEqual(coordinator.request(daemons: [daemon], choose: { .cancel }, stopDaemon: { _ in XCTFail("cancel must not kill") }, reply: { _ in XCTFail("cancel must not reply later") }), .terminateCancel)
        XCTAssertFalse(collector.cancellationRequested)
        XCTAssertTrue(model.runningTest); XCTAssertTrue(model.hasPendingTest)
        let replied = XCTestExpectation(description: "later accepted quit")
        let response = coordinator.request(daemons: [daemon], choose: { .leaveBackground }, stopDaemon: { _ in XCTFail("leave is not kill") }, reply: { _ in XCTAssertTrue(collector.cleaned); replied.fulfill() })
        XCTAssertEqual(response, .terminateLater)
        collector.release(.failure(.cancelled))
        if response == .terminateLater { await fulfillment(of: [replied], timeout: 2) }
        await model.waitForTestCleanup(); model.stop()
    }
    func testUserCancelledTestRemainsOwnedUntilCleanupAndQuitWaitsForIt() async {
        let collector = HeldCollector()
        let model = NetworkMonitoringModel(quality: collector)
        let coordinator = AppTerminationCoordinator(network: model)
        model.runTest(); await fulfillment(of: [collector.entered], timeout: 2)
        model.cancelTest(); await fulfillment(of: [collector.cancelled], timeout: 2)
        XCTAssertTrue(model.hasPendingTest, "UI cancellation cannot drop the collector handle")
        if model.hasPendingTest { model.runTest(); XCTAssertEqual(collector.calls, 1) }
        let replied = XCTestExpectation(description: "already cancelled cleanup drained")
        let response = coordinator.request(daemons: [], choose: { XCTFail("no daemon dialog"); return .cancel }, stopDaemon: { _ in }, reply: { _ in XCTAssertTrue(collector.cleaned); replied.fulfill() })
        XCTAssertEqual(response, .terminateLater)
        collector.release(.failure(.cancelled))
        if response == .terminateLater { await fulfillment(of: [replied], timeout: 2) }
        await model.waitForTestCleanup(); model.stop()
    }
    func testCompletedResultAndFailureNeedNoDeferredReplyAndArePreserved() async {
        let result = NetworkQualityResult(date: .distantPast, interface: "en0", download: 8e6, upload: 4e6, responsiveness: 100, latency: 10)
        for outcome: Result<NetworkQualityResult, NetworkQualityFailure> in [.success(result), .failure(.network)] {
            let collector = HeldCollector()
            let model = NetworkMonitoringModel(quality: collector)
            model.runTest(); await fulfillment(of: [collector.entered], timeout: 2)
            collector.release(outcome); await model.waitForTestCleanup()
            XCTAssertTrue(collector.cleaned); XCTAssertFalse(model.hasPendingTest)
            let beforeResult = model.result, beforeFailure = model.failure
            let coordinator = AppTerminationCoordinator(network: model)
            XCTAssertEqual(coordinator.request(daemons: [], choose: { XCTFail("no daemon dialog"); return .cancel }, stopDaemon: { _ in }, reply: { _ in XCTFail("already drained") }), .terminateNow)
            XCTAssertEqual(model.result, beforeResult); XCTAssertEqual(model.failure, beforeFailure)
            XCTAssertFalse(collector.cancellationRequested)
            model.stop()
        }
    }
    func testReentrantRequestWhileChoosingCannotShowSecondDialog() {
        let model = NetworkMonitoringModel()
        let coordinator = AppTerminationCoordinator(network: model)
        let daemon = UUID()
        var stopped: [UUID] = []
        XCTAssertEqual(coordinator.request(daemons: [daemon], choose: {
            XCTAssertEqual(coordinator.request(daemons: [daemon], choose: { XCTFail("nested dialog"); return .cancel }, stopDaemon: { _ in XCTFail("nested stop") }, reply: { _ in }), .terminateCancel)
            return .kill
        }, stopDaemon: { stopped.append($0) }, reply: { _ in XCTFail("nothing to drain") }), .terminateNow)
        XCTAssertEqual(stopped, [daemon])
    }

    private final class HeldCollector: NetworkQualityTesting, @unchecked Sendable {
        let entered = XCTestExpectation(description: "collector entered")
        let cancelled = XCTestExpectation(description: "collector cancellation requested")
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<NetworkQualityResult, NetworkQualityFailure>, Never>?
        private var wasCancelled = false, didClean = false
        private var callCount = 0
        var calls: Int { lock.lock(); defer { lock.unlock() }; return callCount }
        var cleaned: Bool { lock.lock(); defer { lock.unlock() }; return didClean }
        var cancellationRequested: Bool { lock.lock(); defer { lock.unlock() }; return wasCancelled }
        func release(_ result: Result<NetworkQualityResult, NetworkQualityFailure>) {
            lock.lock(); let c = continuation; continuation = nil; lock.unlock(); c?.resume(returning: result)
        }
        private func markCancelled() {
            lock.lock(); let first = !wasCancelled; wasCancelled = true; lock.unlock()
            if first { cancelled.fulfill() }
        }
        private func markCleaned() { lock.lock(); didClean = true; lock.unlock() }
        func run(interface: String?) async throws -> NetworkQualityResult {
            try await withTaskCancellationHandler {
                let outcome = await withCheckedContinuation { c in
                    lock.lock(); callCount += 1; continuation = c; lock.unlock(); entered.fulfill()
                }
                markCleaned() // Represents completion of process-group termination and reap.
                return try outcome.get()
            } onCancel: { self.markCancelled() }
        }
    }
}
