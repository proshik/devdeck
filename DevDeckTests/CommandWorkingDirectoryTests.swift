import XCTest
@testable import DevDeck

/// `withWorkingDirectory` — the pure half of the per-run directory prompt. The panel itself is
/// AppKit and lives in the view; this is what actually decides what gets launched.
final class CommandWorkingDirectoryTests: XCTestCase {

    private func sample() -> Command {
        Command(id: UUID(), name: "claude", command: "claude", workingDirectory: "/original",
                env: ["A": "b"], openInTerminal: true, routeThroughProxy: true,
                promptForDirectory: true)
    }

    func testBindsTheChosenDirectory() {
        let bound = sample().withWorkingDirectory("/Users/x/project")

        XCTAssertEqual(bound.workingDirectory, "/Users/x/project")
    }

    func testEveryOtherFieldSurvives() {
        let original = sample()
        let bound = original.withWorkingDirectory("/tmp")

        XCTAssertEqual(bound.id, original.id, "same id — supervision state and logs must not split")
        XCTAssertEqual(bound.name, original.name)
        XCTAssertEqual(bound.command, original.command)
        XCTAssertEqual(bound.env, original.env)
        XCTAssertTrue(bound.openInTerminal)
        XCTAssertTrue(bound.routeThroughProxy, "the proxy flag must survive — that's the whole point")
        XCTAssertTrue(bound.promptForDirectory)
    }

    func testNilOrEmptyLeavesTheCommandAlone() {
        let original = sample()

        XCTAssertEqual(original.withWorkingDirectory(nil), original, "callers don't have to branch")
        XCTAssertEqual(original.withWorkingDirectory(""), original)
    }

    func testTheReceiverIsNotMutated() {
        let original = sample()
        _ = original.withWorkingDirectory("/tmp")

        XCTAssertEqual(original.workingDirectory, "/original", "the stored command keeps its own value")
    }
}
