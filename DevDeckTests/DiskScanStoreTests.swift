import XCTest
@testable import DevDeck

/// `disk-scan.json` round-trip, its mode, and what a broken file reads as — in a temp folder.
final class DiskScanStoreTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("disk-scan-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripAndOwnerOnlyMode() throws {
        let fs = FakeDirectoryReader(root: "/h")
        fs.file("/h/p/Cargo.toml", bytes: 1)
        fs.file("/h/p/target/x", bytes: 500_000_000)
        let result = try DiskScanner(reader: fs, root: "/h").scan(now: Date(timeIntervalSince1970: 1_800_000_000))
        let store = DiskScanStore(url: directory.appendingPathComponent("disk-scan.json"))

        store.save(result)

        XCTAssertEqual(store.load(), result)
        let mode = try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testMissingBrokenOrOtherVersionReadsAsNeverScanned() throws {
        let store = DiskScanStore(url: directory.appendingPathComponent("disk-scan.json"))
        XCTAssertNil(store.load())

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("{ broken".utf8).write(to: store.url)
        XCTAssertNil(store.load())

        var result = try DiskScanner(reader: FakeDirectoryReader(root: "/h"), root: "/h").scan()
        result.version = DiskScanResult.currentVersion + 1
        store.save(result)
        XCTAssertNil(store.load())
    }
}

/// The live reader against a real temp tree: link counts, symlinks and allocated sizes as `lstat`
/// gives them — the semantics the scanner relies on.
final class LiveDirectoryReaderTests: XCTestCase {
    func testReadsATempTreeTheWayTheScannerNeeds() throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("reader-\(UUID().uuidString)").resolvingSymlinksInPath().path
        defer { try? fm.removeItem(atPath: base) }
        try fm.createDirectory(atPath: base + "/dir", withIntermediateDirectories: true)
        fm.createFile(atPath: base + "/file", contents: Data(repeating: 1, count: 100_000))
        try fm.linkItem(atPath: base + "/file", toPath: base + "/dir/hard")
        try fm.createSymbolicLink(atPath: base + "/link", withDestinationPath: base + "/dir")

        let reader = LiveDirectoryReader()
        let entries = Dictionary(uniqueKeysWithValues: try reader.entries(of: base).map { ($0.name, $0) })

        XCTAssertEqual(entries["dir"]?.kind, .directory)
        XCTAssertEqual(entries["link"]?.kind, .symlink, "lstat — the link, not its target")
        XCTAssertEqual(entries["file"]?.kind, .file)
        XCTAssertEqual(entries["file"]?.linkCount, 2)
        XCTAssertGreaterThanOrEqual(entries["file"]?.allocatedBytes ?? 0, 100_000)
        XCTAssertThrowsError(try reader.entries(of: base + "/link"), "a link is not listed through")

        let result = try DiskScanner(reader: reader, root: base).scan()
        XCTAssertLessThan(result.tree.bytes, 2 * 100_000 + 64 * 1024, "the hard link is counted once")
    }
}
