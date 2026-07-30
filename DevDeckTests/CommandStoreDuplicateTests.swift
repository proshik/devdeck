import XCTest
@testable import DevDeck

/// `CommandStore.duplicate` — fresh id, adjacent placement, verbatim fields, persistence.
///
/// The copy's exact name is not asserted: it carries `L10n.copyMarker`, which follows the app's
/// current language. `DuplicateNamingTests` pins the naming itself.
@MainActor
final class CommandStoreDuplicateTests: XCTestCase {

    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCopyKeepsEveryFieldButIDAndName() throws {
        let store = CommandStore(configURL: url)
        let original = Command(id: UUID(), name: "forward", command: "kubectl port-forward",
                               workingDirectory: "/tmp", isDaemon: true, needsSudo: true,
                               env: ["A": "1"], appsToQuit: [], openInTerminal: true,
                               watchdogEnabled: true, port: 5432, routeThroughProxy: true,
                               promptForDirectory: true, keepTerminalOpen: true)
        store.upsert(original)

        let copyID = try XCTUnwrap(store.duplicate(commandID: original.id))
        let copy = try XCTUnwrap(store.commandsByID[copyID])

        XCTAssertNotEqual(copy.id, original.id, "fresh id")
        XCTAssertNotEqual(copy.name, original.name, "renamed")
        var expected = original
        expected.id = copy.id
        expected.name = copy.name
        XCTAssertEqual(copy, expected, "every other field copied verbatim, port included")
    }

    func testCopyLandsRightAfterTheOriginal() throws {
        let store = CommandStore(configURL: url)
        let first = Command(id: UUID(), name: "a", command: "echo a")
        let second = Command(id: UUID(), name: "b", command: "echo b")
        store.upsert(first)
        store.upsert(second)

        let copyID = try XCTUnwrap(store.duplicate(commandID: first.id))

        XCTAssertEqual(store.config.commands.map(\.id), [first.id, copyID, second.id])
    }

    func testDaemonCopyStaysADaemon() throws {
        let store = CommandStore(configURL: url)
        let daemon = Command(id: UUID(), name: "d", command: "sleep 1", isDaemon: true)
        store.upsert(daemon)

        let copyID = try XCTUnwrap(store.duplicate(commandID: daemon.id))

        XCTAssertTrue(try XCTUnwrap(store.commandsByID[copyID]).isDaemon,
                      "stays in the daemons section")
    }

    func testChainCopyIsShallowAndAdjacent() throws {
        let store = CommandStore(configURL: url)
        let member = UUID()
        let chain = Chain(id: UUID(), name: "c", commandIDs: [member], stopOnError: false)
        store.upsert(chain)

        let copyID = try XCTUnwrap(store.duplicate(chainID: chain.id))
        let copy = try XCTUnwrap(store.config.chains.first { $0.id == copyID })

        XCTAssertEqual(copy.commandIDs, [member], "members are referenced, not multiplied")
        XCTAssertFalse(copy.stopOnError, "other fields copied verbatim")
        XCTAssertEqual(store.config.chains.map(\.id), [chain.id, copyID])
    }

    func testDuplicatingAnUnknownIDIsANoOp() throws {
        let store = CommandStore(configURL: url)
        let command = Command(id: UUID(), name: "a", command: "echo")
        store.upsert(command)

        XCTAssertNil(store.duplicate(commandID: UUID()))
        XCTAssertNil(store.duplicate(chainID: UUID()))
        XCTAssertEqual(store.config.commands, [command], "nothing changed")
    }

    func testCopyIsPersisted() throws {
        let store = CommandStore(configURL: url)
        let command = Command(id: UUID(), name: "a", command: "echo")
        store.upsert(command)
        let copyID = try XCTUnwrap(store.duplicate(commandID: command.id))

        let fresh = CommandStore(configURL: url)
        fresh.reload()

        XCTAssertEqual(fresh.config.commands.map(\.id), [command.id, copyID],
                       "survived a round-trip through disk")
    }
}
