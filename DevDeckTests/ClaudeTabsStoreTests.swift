import XCTest
@testable import DevDeck

/// The snapshot file is machine state: it must round-trip, and a missing or broken file must read
/// as "no snapshot" rather than throwing — the next capture overwrites it anyway.
final class ClaudeTabsStoreTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude-tabs.json")
    }

    func testRoundTrip() throws {
        let url = tempURL()
        let store = ClaudeTabsStore(url: url)
        let snapshot = ClaudeTabsSnapshot(
            bootTime: Date(timeIntervalSince1970: 1_000_000),
            capturedAt: Date(timeIntervalSince1970: 1_000_100),
            tabs: [ClaudeTabEntry(order: 0, title: "✳ work", workingDirectory: "/tmp/a", sessionID: "s1"),
                   ClaudeTabEntry(order: 1, title: "✳ other", workingDirectory: "/tmp/b", sessionID: nil)])
        try store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
    }

    /// The snapshot lists every project directory this user works in, with AI-generated titles
    /// describing what they were doing in each. `PrivateFile`'s rule is uniform for that reason:
    /// 0600 in a 0700 directory, the same as config.json — and `.atomic` lands a fresh inode at
    /// the default 0644, so the mode has to be reapplied after every write.
    func testSaveLeavesTheSnapshotOwnerOnly() throws {
        let url = tempURL()
        try ClaudeTabsStore(url: url).save(ClaudeTabsSnapshot(
            bootTime: Date(), capturedAt: Date(),
            tabs: [ClaudeTabEntry(order: 0, title: "t", workingDirectory: "/tmp/a", sessionID: "s1")]))

        func mode(of path: URL) throws -> Int {
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
        }
        XCTAssertEqual(try mode(of: url), 0o600)
        XCTAssertEqual(try mode(of: url.deletingLastPathComponent()), 0o700)
    }

    func testMissingFileReadsAsNil() {
        XCTAssertNil(ClaudeTabsStore(url: tempURL()).load())
    }

    func testCorruptFileReadsAsNil() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        XCTAssertNil(ClaudeTabsStore(url: url).load())
    }

    /// A snapshot written before `provider` existed has no such key at all. It must still load —
    /// as a Claude snapshot, since Claude was the only agent this feature knew about then — rather
    /// than fail to decode and silently lose the user's tabs.
    func testOldFormatSnapshotWithoutProviderDecodesAsClaude() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let json = """
        {
          "bootTime": "1970-01-12T13:46:40Z",
          "capturedAt": "1970-01-12T13:48:20Z",
          "tabs": [
            { "order": 0, "title": "✳ work", "workingDirectory": "/tmp/a", "sessionID": "s1" }
          ]
        }
        """
        try Data(json.utf8).write(to: url)

        let loaded = try XCTUnwrap(ClaudeTabsStore(url: url).load())
        XCTAssertEqual(loaded.tabs.map(\.provider), ["claude"])
    }
}
