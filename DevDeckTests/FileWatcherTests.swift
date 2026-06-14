import XCTest
@testable import DevDeck

/// Adopting external edits to config.json: both atomic replacement (rename) and in-place rewrite.
@MainActor
final class FileWatcherTests: XCTestCase {

    private var dir: URL!
    private var file: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        file = dir.appendingPathComponent("config.json")
        try Data("{}".utf8).write(to: file)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attrs[.systemFileNumber] as! NSNumber).uint64Value
    }

    func testDetectsInPlaceRewrite() async throws {
        var calls = 0
        let watcher = FileWatcher(fileURL: file, debounceInterval: 0.05) { calls += 1 }
        watcher.start()
        await sleepUntil({ calls >= 1 }, message: "initial primer on start")

        let before = try inode(file)
        // In-place rewrite (truncate+write): the file's inode is preserved, the directory does not change —
        // this is exactly how python open(w), echo >, and sed -i write files.
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"{"schemaVersion":1}"#.utf8))
        try handle.close()
        XCTAssertEqual(try inode(file), before, "rewrite must not change the inode (otherwise the test covers a different case)")

        await sleepUntil({ calls >= 2 }, message: "in-place rewrite must trigger a reload")
        watcher.stop()
    }

    func testDetectsAtomicReplaceAndSubsequentInPlaceRewrite() async throws {
        var calls = 0
        let watcher = FileWatcher(fileURL: file, debounceInterval: 0.05) { calls += 1 }
        watcher.start()
        await sleepUntil({ calls >= 1 }, message: "initial primer on start")

        // Atomic replacement (temp + rename) — the path used by editors and the app's own save.
        try Data(#"{"commands":[]}"#.utf8).write(to: file, options: .atomic)
        await sleepUntil({ calls >= 2 }, message: "atomic replacement must trigger a reload")

        // After replacement the file's inode is NEW — in-place rewrites must still be caught
        // (the watcher must re-attach to the new inode).
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 0)
        try handle.write(contentsOf: Data(#"{"chains":[]}"#.utf8))
        try handle.close()
        await sleepUntil({ calls >= 3 }, message: "rewrite after atomic replacement must trigger a reload")
        watcher.stop()
    }
}
