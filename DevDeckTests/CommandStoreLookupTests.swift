import XCTest
@testable import DevDeck

/// `commandsByID` — index of commands by id, used for running chains.
@MainActor
final class CommandStoreLookupTests: XCTestCase {

    func testCommandsByIDIndexesAllCommands() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")

        let a = Command(id: UUID(), name: "a", command: "echo a")
        let b = Command(id: UUID(), name: "b", command: "echo b")
        try ConfigCodec.encode(Config(commands: [a, b])).write(to: url, options: .atomic)

        let store = CommandStore(configURL: url)
        store.reload()

        XCTAssertEqual(store.commandsByID[a.id], a)
        XCTAssertEqual(store.commandsByID[b.id], b)
        XCTAssertEqual(store.commandsByID.count, 2)
    }

    func testCommandsByIDFirstWinsOnDuplicateID() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("config.json")

        let shared = UUID()
        let first = Command(id: shared, name: "first", command: "echo 1")
        let second = Command(id: shared, name: "second", command: "echo 2")
        try ConfigCodec.encode(Config(commands: [first, second])).write(to: url, options: .atomic)

        let store = CommandStore(configURL: url)
        store.reload()

        XCTAssertEqual(store.commandsByID.count, 1, "duplicate id must not crash the app")
        XCTAssertEqual(store.commandsByID[shared], first, "the first command wins")
    }
}
