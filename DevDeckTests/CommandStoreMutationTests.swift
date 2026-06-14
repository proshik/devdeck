import XCTest
@testable import DevDeck

/// `CommandStore` mutations from the editor (Phase 4): upsert/delete with atomic persistence.
@MainActor
final class CommandStoreMutationTests: XCTestCase {

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

    func testUpsertAddsThenUpdatesCommandAndPersists() throws {
        let store = CommandStore(configURL: url)
        let command = Command(id: UUID(), name: "a", command: "echo")

        store.upsert(command)
        XCTAssertEqual(store.config.commands, [command])

        var renamed = command
        renamed.name = "renamed"
        store.upsert(renamed)
        XCTAssertEqual(store.config.commands, [renamed], "updated by id, no duplicate")

        let fresh = CommandStore(configURL: url)
        fresh.reload()
        XCTAssertEqual(fresh.config.commands, [renamed], "persisted to disk")
    }

    func testDeleteCommandStripsItFromChains() throws {
        let store = CommandStore(configURL: url)
        let command = Command(id: UUID(), name: "a", command: "echo")
        let chain = Chain(id: UUID(), name: "c", commandIDs: [command.id])
        store.upsert(command)
        store.upsert(chain)

        store.delete(commandID: command.id)

        XCTAssertTrue(store.config.commands.isEmpty)
        XCTAssertEqual(store.config.chains.first?.commandIDs, [], "id removed from chains")
    }

    func testUpsertAndDeleteChain() throws {
        let store = CommandStore(configURL: url)
        let chain = Chain(id: UUID(), name: "c", commandIDs: [])

        store.upsert(chain)
        XCTAssertEqual(store.config.chains, [chain])

        store.delete(chainID: chain.id)
        XCTAssertTrue(store.config.chains.isEmpty)
    }

    func testSetVMMonitoringPersists() {
        let store = CommandStore(configURL: url)
        store.setVMMonitoring(false)
        XCTAssertFalse(store.config.settings.vmMemoryMonitoring)
        let store2 = CommandStore(configURL: url)
        store2.reload()
        XCTAssertFalse(store2.config.settings.vmMemoryMonitoring)
    }
}
