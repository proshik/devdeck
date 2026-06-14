import XCTest
@testable import DevDeck

/// Unit tests for routing and the sudo prefix — no real processes.
final class RunnerRoutingTests: XCTestCase {

    func testRoutesSudoVsNonSudoToCorrectRunner() {
        let zshFake = FakeCommandRunner()
        let sudoFake = FakeCommandRunner()
        let routing = RoutingCommandRunner(zsh: zshFake, sudo: sudoFake)

        let plain = Command(id: UUID(), name: "p", command: "echo")
        let privileged = Command(id: UUID(), name: "s", command: "purge", needsSudo: true)

        _ = routing.start(plain)
        _ = routing.start(privileged)

        XCTAssertEqual(zshFake.startedCommandIDs, [plain.id])
        XCTAssertEqual(sudoFake.startedCommandIDs, [privileged.id])
    }

    func testRoutesOpenInTerminalToTerminalRunner() {
        let zshFake = FakeCommandRunner()
        let sudoFake = FakeCommandRunner()
        let terminalFake = FakeCommandRunner()
        let routing = RoutingCommandRunner(zsh: zshFake, sudo: sudoFake, terminal: terminalFake)

        // openInTerminal takes priority even over needsSudo
        let inTerminal = Command(id: UUID(), name: "t", command: "just dev-start", openInTerminal: true)
        let terminalSudo = Command(id: UUID(), name: "ts", command: "x", needsSudo: true, openInTerminal: true)

        _ = routing.start(inTerminal)
        _ = routing.start(terminalSudo)

        XCTAssertEqual(terminalFake.startedCommandIDs, [inTerminal.id, terminalSudo.id])
        XCTAssertTrue(zshFake.startedCommandIDs.isEmpty)
        XCTAssertTrue(sudoFake.startedCommandIDs.isEmpty)
    }

    func testSudoInnerShellPrefixesCdAndExport() {
        let command = Command(
            id: UUID(), name: "s", command: "purge",
            workingDirectory: "/tmp", needsSudo: true, env: ["A": "1"]
        )
        XCTAssertEqual(SudoCommandRunner.buildInnerShell(command), "cd '/tmp'; export A='1'; purge")
    }

    func testShQuoteEscapesSingleQuote() {
        XCTAssertEqual(SudoCommandRunner.shQuote("a'b"), "'a'\\''b'")
    }
}
