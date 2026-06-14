import XCTest
@testable import DevDeck

/// Store tests. Logic (save / corrupted / external / self-write) is verified
/// deterministically via synchronous `reload()`, without FileWatcher involvement.
/// The live DispatchSource watcher is covered by a single integration test with a timeout.
@MainActor
final class CommandStoreTests: XCTestCase {

    private var dir: URL!
    private var configURL: URL!
    private var store: CommandStore?

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        configURL = dir.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        store?.stop()
        store = nil
        try? FileManager.default.removeItem(at: dir)
    }

    private func writeFile(_ config: Config) throws {
        try ConfigCodec.encode(config).write(to: configURL, options: .atomic)
    }

    private func sampleConfig(name: String = "colima stop") -> Config {
        Config(commands: [Command(id: UUID(), name: name, command: "colima stop")])
    }

    // MARK: first launch

    func testStartCopiesBundledDefaultOnFirstRun() throws {
        let seed = sampleConfig(name: "seeded")
        let defaultData = try ConfigCodec.encode(seed)
        let store = CommandStore(configURL: configURL, defaultConfigData: defaultData)
        self.store = store

        store.start()

        XCTAssertEqual(store.config, seed)
        XCTAssertNil(store.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path))
    }

    func testStartWritesEmptyConfigWhenNoBundledDefault() throws {
        let store = CommandStore(configURL: configURL, defaultConfigData: nil)
        self.store = store

        store.start()

        XCTAssertEqual(store.config, .empty)
        XCTAssertNil(store.error)
        XCTAssertTrue(FileManager.default.fileExists(atPath: configURL.path),
                      "file must always exist — even without a bundled default")
    }

    func testStartDoesNotClobberExistingConfig() throws {
        let existing = sampleConfig(name: "manual edit")
        try writeFile(existing)
        let store = CommandStore(configURL: configURL,
                                 defaultConfigData: try ConfigCodec.encode(sampleConfig(name: "default")))
        self.store = store

        store.start()

        XCTAssertEqual(store.config, existing, "first launch must not overwrite an existing file")
    }

    // MARK: save / load

    func testSavePersistsAndReloadsEqual() throws {
        let store = CommandStore(configURL: configURL)
        self.store = store
        var config = sampleConfig()
        config.commands.append(Command(id: UUID(), name: "minikube stop", command: "minikube stop"))

        try store.save(config)

        XCTAssertEqual(store.config, config)
        let fresh = CommandStore(configURL: configURL)
        fresh.reload()
        XCTAssertEqual(fresh.config, config)
    }

    // MARK: corrupted JSON

    func testCorruptedJSONKeepsLastValidConfigAndSurfacesError() throws {
        let valid = sampleConfig(name: "valid")
        try writeFile(valid)
        let store = CommandStore(configURL: configURL)
        self.store = store
        store.reload()
        XCTAssertEqual(store.config, valid)
        XCTAssertNil(store.error)

        try Data("{ this is not json ".utf8).write(to: configURL, options: .atomic)
        store.reload()

        XCTAssertEqual(store.config, valid, "corrupted JSON does not overwrite the last valid version")
        XCTAssertNotNil(store.error, "error must be visible in the UI")

        // Manually fixing the file → the next reload clears the error.
        let fixed = sampleConfig(name: "fixed")
        try writeFile(fixed)
        store.reload()
        XCTAssertEqual(store.config, fixed)
        XCTAssertNil(store.error)
    }

    func testReloadOnMissingFileKeepsConfigAndSurfacesError() throws {
        let valid = sampleConfig(name: "valid")
        try writeFile(valid)
        let store = CommandStore(configURL: configURL)
        self.store = store
        store.reload()
        XCTAssertEqual(store.config, valid)
        XCTAssertNil(store.error)

        try FileManager.default.removeItem(at: configURL)
        let changed = store.reload()

        XCTAssertFalse(changed)
        XCTAssertEqual(store.config, valid, "deleting the file does not overwrite the last valid version")
        XCTAssertNotNil(store.error)

        // Restoring the file → the next reload clears the error.
        let restored = sampleConfig(name: "restored")
        try writeFile(restored)
        store.reload()
        XCTAssertEqual(store.config, restored)
        XCTAssertNil(store.error)
    }

    func testSaveFailureThrowsAndLeavesConfigUnchanged() throws {
        // Make a regular file the parent of the config path → cannot create a directory or write there.
        let blocker = dir.appendingPathComponent("blocker")
        try Data("x".utf8).write(to: blocker)
        let badURL = blocker.appendingPathComponent("config.json")
        let store = CommandStore(configURL: badURL)
        self.store = store
        XCTAssertEqual(store.config, .empty)

        XCTAssertThrowsError(try store.save(sampleConfig()))
        XCTAssertEqual(store.config, .empty, "a failed save does not change the in-memory state")
    }

    func testCommandMissingRequiredFieldKeepsLastValidAndSurfacesError() throws {
        let valid = sampleConfig(name: "valid")
        try writeFile(valid)
        let store = CommandStore(configURL: configURL)
        self.store = store
        store.reload()

        // Structurally valid JSON, but the command is missing the required "command" field.
        let bad = Data("""
        { "commands": [ { "name": "broken" } ] }
        """.utf8)
        try bad.write(to: configURL, options: .atomic)
        store.reload()

        XCTAssertEqual(store.config, valid, "an invalid element does not overwrite the last valid version")
        let error = try XCTUnwrap(store.error)
        XCTAssertTrue(error.contains("command"), "error points to the missing field: \(error)")
    }

    func testTypeMismatchProducesReadableErrorWithoutEmptyField() throws {
        let valid = sampleConfig(name: "valid")
        try writeFile(valid)
        let store = CommandStore(configURL: configURL)
        self.store = store
        store.reload()

        // Root is an array instead of an object: typeMismatch with an empty codingPath.
        try Data("[]".utf8).write(to: configURL, options: .atomic)
        store.reload()

        XCTAssertEqual(store.config, valid)
        let error = try XCTUnwrap(store.error)
        XCTAssertFalse(error.contains("«»"), "message must not contain an empty field name: \(error)")
    }

    // MARK: external edits and suppression of own writes

    func testReloadPicksUpExternalEdit() throws {
        try writeFile(sampleConfig(name: "before"))
        let store = CommandStore(configURL: configURL)
        self.store = store
        store.reload()

        let external = sampleConfig(name: "after")
        try writeFile(external)
        let changed = store.reload()

        XCTAssertTrue(changed)
        XCTAssertEqual(store.config, external)
    }

    func testReloadOfOwnWriteIsNoOp() throws {
        let store = CommandStore(configURL: configURL)
        self.store = store
        var config = sampleConfig()
        config.commands.append(Command(id: UUID(), name: "extra", command: "echo"))
        try store.save(config)

        // Re-reading the exact same write must not change state (Equatable guard).
        let changed = store.reload()

        XCTAssertFalse(changed, "echo of own write does not publish a change")
        XCTAssertEqual(store.config, config)
    }

    // MARK: live watcher (deterministic, directly via FileWatcher)

    func testFileWatcherDeliversEventForExternalAtomicWrite() throws {
        try writeFile(sampleConfig(name: "initial"))

        let armed = expectation(description: "source started watching (primer)")
        let changed = expectation(description: "event delivered for external atomic write")
        changed.assertForOverFulfill = false
        var didArm = false
        let watcher = FileWatcher(fileURL: configURL) {
            if !didArm {
                didArm = true
                armed.fulfill()        // primer fires strictly after resume()
            } else {
                changed.fulfill()
            }
        }
        watcher.start()
        defer { watcher.stop() }

        // Source is guaranteed live — write only after it is ready.
        wait(for: [armed], timeout: 5)

        // Atomic write (temp + rename) — what editors and our save() do.
        try ConfigCodec.encode(sampleConfig(name: "external")).write(to: configURL, options: .atomic)

        wait(for: [changed], timeout: 5)
    }
}
