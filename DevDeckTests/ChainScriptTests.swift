import XCTest
@testable import DevDeck

final class ChainScriptTests: XCTestCase {

    private func cmd(_ name: String, _ command: String, daemon: Bool = false,
                     sudo: Bool = false, wd: String? = nil, env: [String: String] = [:]) -> Command {
        Command(id: UUID(), name: name, command: command, workingDirectory: wd,
                isDaemon: daemon, needsSudo: sudo, env: env)
    }

    func testStopOnErrorJoinsWithAnd() {
        let a = cmd("a", "echo a"); let b = cmd("b", "echo b")
        let chain = Chain(name: "c", commandIDs: [a.id, b.id], stopOnError: true, openInTerminal: true)
        let s = ChainScript.build(chain, commands: [a.id: a, b.id: b])
        XCTAssertTrue(s.contains(" && "))
        XCTAssertFalse(s.contains(" ; "))
        XCTAssertTrue(s.contains("echo a") && s.contains("echo b"))
    }

    func testNoStopOnErrorJoinsWithSemicolon() {
        let a = cmd("a", "echo a"); let b = cmd("b", "echo b")
        let chain = Chain(name: "c", commandIDs: [a.id, b.id], stopOnError: false, openInTerminal: true)
        let s = ChainScript.build(chain, commands: [a.id: a, b.id: b])
        XCTAssertTrue(s.contains(" ; "))
        XCTAssertFalse(s.contains(" && "))
    }

    func testStepCdEnvSudo() {
        let a = cmd("a", "just build", wd: "/work", env: ["E": "1"])
        let b = cmd("b", "purge", sudo: true)
        let chain = Chain(name: "c", commandIDs: [a.id, b.id], stopOnError: true, openInTerminal: true)
        let s = ChainScript.build(chain, commands: [a.id: a, b.id: b])
        XCTAssertTrue(s.contains("cd '/work'"))
        XCTAssertTrue(s.contains("export E='1'"))
        XCTAssertTrue(s.contains("sudo purge"))
    }

    func testDaemonStepBackgrounded() {
        let d = cmd("pf", "kubectl port-forward x", daemon: true)
        let chain = Chain(name: "c", commandIDs: [d.id], stopOnError: true, openInTerminal: true)
        let s = ChainScript.build(chain, commands: [d.id: d])
        XCTAssertTrue(s.contains(") &"), "a daemon must run in the background: \(s)")
    }

    func testMissingCommandIsFailingStep() {
        let chain = Chain(name: "c", commandIDs: [UUID()], stopOnError: true, openInTerminal: true)
        let s = ChainScript.build(chain, commands: [:])
        XCTAssertTrue(s.contains("false"))
        XCTAssertTrue(s.contains(L10n.noCommandMarker))
    }

    func testMarkersWithIndexAndName() {
        let a = cmd("Build", "echo a")
        let chain = Chain(name: "c", commandIDs: [a.id], openInTerminal: true)
        let s = ChainScript.build(chain, commands: [a.id: a])
        XCTAssertTrue(s.contains("[1/1]"))
        XCTAssertTrue(s.contains("Build"))
    }

    func testChainOpenInTerminalRoundTrips() throws {
        let chain = Chain(name: "c", openInTerminal: true)
        let data = try JSONEncoder().encode(chain)
        XCTAssertTrue(try JSONDecoder().decode(Chain.self, from: data).openInTerminal)
    }
}
