import XCTest
@testable import DevDeck

@MainActor
final class ProcessManagerMemoryTests: XCTestCase {

    private func app(_ id: String, _ name: String) -> AppRef { AppRef(bundleID: id, name: name) }

    func testCommandQuitsBeforeAndRelaunchesAfter() async {
        let runner = FakeCommandRunner()
        let apps = FakeAppController()
        apps.willQuit = ["com.chrome"]
        let c = Command(id: UUID(), name: "build", command: "x", appsToQuit: [app("com.chrome", "Chrome")])
        runner.eagerScripts[c.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        let m = ProcessManager(runner: runner, appController: apps)

        m.run(c)
        await yieldUntil { !apps.relaunchCalls.isEmpty }

        XCTAssertEqual(apps.quitCalls, [["com.chrome"]])
        XCTAssertEqual(apps.relaunchCalls, [["com.chrome"]])
        XCTAssertEqual(m.states[c.id], .succeeded)
    }

    func testAppThatWontQuitIsNotRelaunched() async {
        let runner = FakeCommandRunner()
        let apps = FakeAppController()
        apps.willQuit = ["com.chrome"]   // Slack will NOT quit
        let c = Command(id: UUID(), name: "build", command: "x",
                        appsToQuit: [app("com.chrome", "Chrome"), app("com.slack", "Slack")])
        runner.eagerScripts[c.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        let m = ProcessManager(runner: runner, appController: apps)

        m.run(c)
        await yieldUntil { !apps.relaunchCalls.isEmpty }

        XCTAssertEqual(apps.relaunchCalls, [["com.chrome"]], "an app that didn't quit is not relaunched")
    }

    func testEmptyAppsToQuitDoesNotTouchAppController() async {
        let runner = FakeCommandRunner()
        let apps = FakeAppController()
        let c = Command(id: UUID(), name: "plain", command: "x")
        runner.eagerScripts[c.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        let m = ProcessManager(runner: runner, appController: apps)

        m.run(c)
        await yieldUntil { m.states[c.id] == .succeeded }

        XCTAssertTrue(apps.quitCalls.isEmpty)
        XCTAssertTrue(apps.relaunchCalls.isEmpty)
    }

    func testRelaunchHappensEvenOnFailure() async {
        let runner = FakeCommandRunner()
        let apps = FakeAppController()
        apps.willQuit = ["com.chrome"]
        let c = Command(id: UUID(), name: "build", command: "x", appsToQuit: [app("com.chrome", "Chrome")])
        runner.eagerScripts[c.id] = [.started(pid: 1), .terminated(exitCode: 2)]
        let m = ProcessManager(runner: runner, appController: apps)

        m.run(c)
        await yieldUntil { !apps.relaunchCalls.isEmpty }

        XCTAssertEqual(apps.relaunchCalls, [["com.chrome"]], "relaunch always happens — even on failure")
        XCTAssertEqual(m.states[c.id], .failed(code: 2))
    }

    func testReRunMemoryCommandRelaunchesOnlyFromCurrentRun() async {
        let runner = FakeCommandRunner()
        runner.autoTerminateOnStopCode = nil   // terminate manually
        let apps = FakeAppController()
        apps.willQuit = ["com.chrome"]
        let c = Command(id: UUID(), name: "build", command: "x", appsToQuit: [app("com.chrome", "Chrome")])
        let m = ProcessManager(runner: runner, appController: apps)

        m.run(c)                                                   // run 1: quit, start (hold)
        await yieldUntil { apps.quitCalls.count == 1 && runner.controller(for: c.id) != nil }
        try! XCTUnwrap(runner.controller(for: c.id)).started()
        await yieldUntil { m.states[c.id] == .running }

        m.run(c)                                                   // run 2 PREEMPTS run 1
        await yieldUntil { apps.quitCalls.count == 2 }
        let c2 = try! XCTUnwrap(runner.controller(for: c.id))
        c2.started()
        await yieldUntil { m.states[c.id] == .running }
        c2.terminate(0)
        await yieldUntil { !apps.relaunchCalls.isEmpty }
        await Task.yield(); await Task.yield()

        XCTAssertEqual(apps.relaunchCalls.count, 1, "only the current run triggers relaunch, stale relaunch is suppressed")
    }

    func testChainRelaunchesOnlyClosedSubsetOfUnion() async {
        let runner = FakeCommandRunner()
        let apps = FakeAppController()
        apps.willQuit = ["com.chrome"]   // Slack will NOT quit
        let c0 = Command(id: UUID(), name: "a", command: "x", appsToQuit: [app("com.chrome", "Chrome")])
        let c1 = Command(id: UUID(), name: "b", command: "y", appsToQuit: [app("com.slack", "Slack")])
        runner.eagerScripts[c0.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        runner.eagerScripts[c1.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        let chain = Chain(id: UUID(), name: "seq", commandIDs: [c0.id, c1.id], stopOnError: true)
        let m = ProcessManager(runner: runner, appController: apps)

        m.run(chain, commands: [c0.id: c0, c1.id: c1])
        await yieldUntil { m.chainStates[chain.id] == .succeeded && !apps.relaunchCalls.isEmpty }

        XCTAssertEqual(apps.relaunchCalls, [["com.chrome"]], "only apps that actually quit from the union are relaunched")
    }

    func testChainQuitsUnionOnceAndRelaunchesOnce() async {
        let runner = FakeCommandRunner()
        let apps = FakeAppController()
        apps.willQuit = ["com.chrome", "com.slack"]
        let c0 = Command(id: UUID(), name: "a", command: "x", appsToQuit: [app("com.chrome", "Chrome")])
        let c1 = Command(id: UUID(), name: "b", command: "y", appsToQuit: [app("com.slack", "Slack")])
        runner.eagerScripts[c0.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        runner.eagerScripts[c1.id] = [.started(pid: 1), .terminated(exitCode: 0)]
        let chain = Chain(id: UUID(), name: "seq", commandIDs: [c0.id, c1.id], stopOnError: true)
        let m = ProcessManager(runner: runner, appController: apps)

        m.run(chain, commands: [c0.id: c0, c1.id: c1])
        await yieldUntil { m.chainStates[chain.id] == .succeeded && !apps.relaunchCalls.isEmpty }

        XCTAssertEqual(apps.quitCalls.count, 1, "the union is quit exactly ONCE")
        XCTAssertEqual(apps.quitCalls.first, ["com.chrome", "com.slack"])
        XCTAssertEqual(apps.relaunchCalls.count, 1, "relaunched exactly ONCE")
        XCTAssertEqual(apps.relaunchCalls.first, ["com.chrome", "com.slack"])
    }
}
