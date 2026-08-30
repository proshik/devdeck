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
}
