import XCTest
@testable import DevDeck

/// The shipped `default-config.json` must be valid (guarding against the "broken bundled default" risk from Phase 1).
/// In a hosted test `Bundle.main` = DevDeck.app, which is where the resource lives.
final class DefaultConfigTests: XCTestCase {

    func testBundledDefaultConfigIsValid() throws {
        let url = try XCTUnwrap(
            Bundle.main.url(forResource: "default-config", withExtension: "json"),
            "default-config.json must be present in the app bundle"
        )
        let config = try ConfigCodec.decode(Data(contentsOf: url))

        XCTAssertFalse(config.commands.isEmpty, "contains example commands")
        XCTAssertTrue(config.commands.contains { $0.isDaemon }, "contains a daemon example")
        XCTAssertTrue(config.commands.contains { $0.needsSudo }, "contains a sudo command example")
        XCTAssertFalse(config.chains.isEmpty, "contains a chain example")

        // The default must not carry any user- or project-specific paths.
        for command in config.commands {
            XCTAssertNil(command.workingDirectory, "example '\(command.name)' must not depend on machine-specific paths")
        }

        // Chains must only reference commands that exist.
        let commandIDs = Set(config.commands.map(\.id))
        for chain in config.chains {
            for stepID in chain.commandIDs {
                XCTAssertTrue(commandIDs.contains(stepID), "chain step in '\(chain.name)' references an existing command")
            }
        }
    }
}
