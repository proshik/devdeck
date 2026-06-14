import XCTest
@testable import DevDeck

/// Reordering commands/daemons/chains from the sidebar (display order in the popover).
@MainActor
final class CommandStoreMoveTests: XCTestCase {

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

    private func cmd(_ name: String, daemon: Bool = false) -> Command {
        Command(id: UUID(), name: name, command: "echo", isDaemon: daemon)
    }

    func testMoveCommandsReordersOnlyNonDaemonsAndPersists() throws {
        let store = CommandStore(configURL: url)
        // Mixed array: daemons interspersed among regular commands.
        let a = cmd("a"), d1 = cmd("d1", daemon: true), b = cmd("b"), c = cmd("c"), d2 = cmd("d2", daemon: true)
        for command in [a, d1, b, c, d2] { store.upsert(command) }

        // In the "Commands" section [a, b, c]: drag c (index 2) to the top (before index 0).
        store.moveCommands(IndexSet(integer: 2), to: 0, daemons: false)

        XCTAssertEqual(store.config.commands.filter { !$0.isDaemon }.map(\.name), ["c", "a", "b"])
        XCTAssertEqual(store.config.commands.filter(\.isDaemon).map(\.name), ["d1", "d2"],
                       "daemon order is untouched")
        XCTAssertEqual(store.config.commands.map(\.name), ["c", "d1", "a", "b", "d2"],
                       "daemon positions in the full array are preserved")

        let fresh = CommandStore(configURL: url)
        fresh.reload()
        XCTAssertEqual(fresh.config.commands.map(\.name), ["c", "d1", "a", "b", "d2"], "persisted to disk")
    }

    func testMoveCommandsReordersDaemonsOnly() throws {
        let store = CommandStore(configURL: url)
        let a = cmd("a"), d1 = cmd("d1", daemon: true), d2 = cmd("d2", daemon: true)
        for command in [a, d1, d2] { store.upsert(command) }

        // In the "Daemons" section [d1, d2]: drag d2 to the top.
        store.moveCommands(IndexSet(integer: 1), to: 0, daemons: true)

        XCTAssertEqual(store.config.commands.map(\.name), ["a", "d2", "d1"])
    }

    func testMoveChainsReordersAndPersists() throws {
        let store = CommandStore(configURL: url)
        let x = Chain(id: UUID(), name: "x", commandIDs: [])
        let y = Chain(id: UUID(), name: "y", commandIDs: [])
        store.upsert(x)
        store.upsert(y)

        store.moveChains(IndexSet(integer: 1), to: 0)

        XCTAssertEqual(store.config.chains.map(\.name), ["y", "x"])
        let fresh = CommandStore(configURL: url)
        fresh.reload()
        XCTAssertEqual(fresh.config.chains.map(\.name), ["y", "x"], "persisted to disk")
    }
}
