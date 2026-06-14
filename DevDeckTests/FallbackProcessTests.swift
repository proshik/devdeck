import XCTest
@testable import DevDeck

/// Wrapper for "primary run + fallback on auth failure" (Touch ID sudo → osascript).
@MainActor
final class FallbackProcessTests: XCTestCase {

    private let cmdA = Command(id: UUID(), name: "primary", command: "x")
    private let cmdB = Command(id: UUID(), name: "fallback", command: "x")

    private func makeWrapper(
        primary: FakeCommandRunner, fallback: FakeCommandRunner,
        fallbackStarted: @escaping @Sendable () -> Void = {}
    ) -> FallbackProcess {
        let a = cmdA, b = cmdB
        return FallbackProcess(
            primary: { primary.start(a) },
            fallback: { fallbackStarted(); return fallback.start(b) },
            shouldFallback: SudoCommandRunner.isAuthFailure
        )
    }

    func testForwardsPrimaryVerbatimOnSuccess() async {
        let primary = FakeCommandRunner(), fallback = FakeCommandRunner()
        primary.eagerScripts[cmdA.id] = [
            .started(pid: 42), .line("working", stream: .stdout), .terminated(exitCode: 0),
        ]
        let wrapper = makeWrapper(primary: primary, fallback: fallback)

        let events = await collectEvents(wrapper)
        XCTAssertEqual(events, [
            .started(pid: 42), .line("working", stream: .stdout), .terminated(exitCode: 0),
        ])
        XCTAssertTrue(fallback.startedCommandIDs.isEmpty, "fallback must not be started")
    }

    func testFallsBackOnAuthFailure() async {
        let primary = FakeCommandRunner(), fallback = FakeCommandRunner()
        primary.eagerScripts[cmdA.id] = [
            .started(pid: nil),
            .line("sudo: a terminal is required to read the password", stream: .stderr),
            .line("sudo: a password is required", stream: .stderr),
            .terminated(exitCode: 1),
        ]
        fallback.eagerScripts[cmdB.id] = [
            .started(pid: nil), .line("done", stream: .stdout), .terminated(exitCode: 0),
        ]
        let wrapper = makeWrapper(primary: primary, fallback: fallback)

        let events = await collectEvents(wrapper)
        XCTAssertEqual(events.filter { if case .started = $0 { return true }; return false }.count, 1,
                       "exactly one .started for the entire run")
        XCTAssertEqual(events.last, .terminated(exitCode: 0), "terminal event is from the fallback")
        XCTAssertFalse(events.contains(.terminated(exitCode: 1)), "auth-failure terminal is suppressed")
        XCTAssertTrue(events.contains(.line("done", stream: .stdout)))
    }

    func testNoFallbackWhenCommandProducedOutput() async {
        let primary = FakeCommandRunner(), fallback = FakeCommandRunner()
        primary.eagerScripts[cmdA.id] = [
            .started(pid: 1),
            .line("partial output", stream: .stdout),
            .line("sudo: a password is required", stream: .stderr),   // sudo marker appears in the command's own output
            .terminated(exitCode: 1),
        ]
        let wrapper = makeWrapper(primary: primary, fallback: fallback)

        let events = await collectEvents(wrapper)
        XCTAssertEqual(events.last, .terminated(exitCode: 1), "a genuine command failure is not a reason to fall back")
        XCTAssertTrue(fallback.startedCommandIDs.isEmpty)
    }

    func testStopSuppressesFallback() async {
        let primary = FakeCommandRunner(), fallback = FakeCommandRunner()
        primary.autoTerminateOnStopCode = 1   // dies with a code that resembles an auth failure
        let wrapper = makeWrapper(primary: primary, fallback: fallback)

        await yieldUntil { primary.controller(for: cmdA.id) != nil }
        let ctrl = primary.controller(for: cmdA.id)!
        ctrl.started(pid: nil)
        ctrl.line("sudo: a password is required", .stderr)
        wrapper.stop()   // user stopped it → the fallback dialog must not appear

        let events = await collectEvents(wrapper)
        XCTAssertEqual(events.last, .terminated(exitCode: 1))
        XCTAssertTrue(fallback.startedCommandIDs.isEmpty, "fallback is not started after stop")
        XCTAssertEqual(ctrl.stopCount, 1, "stop reached the primary run")
    }

    func testForwardsCancelledFromFallback() async {
        let primary = FakeCommandRunner(), fallback = FakeCommandRunner()
        primary.eagerScripts[cmdA.id] = [
            .started(pid: nil),
            .line("sudo: a password is required", stream: .stderr),
            .terminated(exitCode: 1),
        ]
        let wrapper = makeWrapper(primary: primary, fallback: fallback)
        await yieldUntil { fallback.controller(for: cmdB.id) != nil }
        fallback.controller(for: cmdB.id)!.cancel()   // user cancelled the password dialog

        let events = await collectEvents(wrapper)
        XCTAssertEqual(events.last, .cancelled, "fallback dialog cancellation propagates to the manager")
    }
}
