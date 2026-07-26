import XCTest
@testable import DevDeck

/// The file the terminal helper reads: the pure text below, plus `LiveProxyEnvFile` itself against
/// an injected temp path — never the real `~/.config`. The manager's own bookkeeping is covered
/// separately through `FakeProxyEnvFile`.
final class ProxyEnvFileTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func mode(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attributes[.posixPermissions] as? Int)
    }

    func testContentsCarryTheTwoKeysTheHelperReads() {
        let text = proxyEnvFileContents(url: "http://192.168.31.117:9999", lanPrefix: "192.168.31")

        XCTAssertTrue(text.contains("DEVDECK_PROXY_URL=http://192.168.31.117:9999"))
        XCTAssertTrue(text.contains("DEVDECK_PROXY_LAN=192.168.31"))
    }

    func testContentsAreNotShellExecutable() {
        // The helper reads keys instead of sourcing the file, so a tampered file can't run code.
        // Emitting `export` lines would invite someone to "simplify" the helper into `source`.
        let text = proxyEnvFileContents(url: "http://h:1", lanPrefix: "10.0.0")

        XCTAssertFalse(text.contains("export "))
        XCTAssertTrue(text.hasPrefix("#"), "leads with the do-not-edit header")
        XCTAssertTrue(text.hasSuffix("\n"), "trailing newline so `sed` sees the last line")
    }

    func testURLIsBuiltByTheSameHelperAsTheInjectedEnv() {
        // One builder for both paths — otherwise escaping could drift between them.
        let url = proxyURL(host: "h", port: 1, user: "u@corp", pass: "p:a@ss/word")

        XCTAssertEqual(url, "http://u%40corp:p%3Aa%40ss%2Fword@h:1")
        XCTAssertEqual(proxyEnv(host: "h", port: 1, user: "u@corp", pass: "p:a@ss/word")["HTTPS_PROXY"], url)
    }

    func testURLWithoutCredentials() {
        XCTAssertEqual(proxyURL(host: "192.168.31.117", port: 9999, user: nil, pass: nil),
                       "http://192.168.31.117:9999")
        XCTAssertEqual(proxyURL(host: "h", port: 1, user: "", pass: "p"), "http://h:1",
                       "an empty user must not produce a ':p@' prefix")
    }

    // MARK: - LiveProxyEnvFile

    /// The whole point of the POSIX write path: this file can hold the proxy password in plaintext.
    func testTheWrittenFileIsOwnerOnly() throws {
        let url = dir.appendingPathComponent(".config/devdeck/proxy.env")

        LiveProxyEnvFile(url: url).write("DEVDECK_PROXY_URL=http://dev:s3cret@192.168.31.117:9999\n")

        XCTAssertEqual(try mode(of: url), 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "DEVDECK_PROXY_URL=http://dev:s3cret@192.168.31.117:9999\n")
    }

    /// An atomic write-then-rename (`Data.write(to:)`, `FileManager.createFile`) fills a sibling
    /// `proxy.env.sb-…` at 0644 and renames it over the target. That sibling is a world-readable
    /// copy of the password while the write is in flight, and a crash mid-write strands it forever —
    /// removal only unlinks `proxy.env`.
    ///
    /// A rename cannot be caught after the fact by listing the directory, so the tell is the inode:
    /// writing in place keeps it, replacing the file changes it. Both are asserted — the listing
    /// catches a stranded sibling, the inode catches the rename that produces one.
    func testWritingIsInPlaceAndLeavesNoSiblingTempFile() throws {
        let url = dir.appendingPathComponent(".config/devdeck/proxy.env")
        let writer = LiveProxyEnvFile(url: url)

        writer.write("DEVDECK_PROXY_URL=http://a:1\n")
        let firstInode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)
        writer.write("DEVDECK_PROXY_URL=http://b:2\n")
        let secondInode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int)

        XCTAssertEqual(firstInode, secondInode, "a changed inode means a temp file was renamed over it")
        let entries = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
        XCTAssertEqual(entries, ["proxy.env"], "a temp sibling would be a world-readable copy")
        XCTAssertEqual(try mode(of: url), 0o600, "and it stays owner-only across rewrites")
    }

    /// `O_CREAT`'s mode argument is ignored when the file already exists, so a file left at 0644 by
    /// an older build (or by hand) has to be tightened explicitly — before any byte is written.
    func testAPreExistingWorldReadableFileIsTightened() throws {
        let url = dir.appendingPathComponent("proxy.env")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path,
                                                    contents: Data("a much longer stale line\n".utf8),
                                                    attributes: [.posixPermissions: 0o644]))
        XCTAssertEqual(try mode(of: url), 0o644, "sanity: starts world-readable")

        LiveProxyEnvFile(url: url).write("DEVDECK_PROXY_URL=http://dev:s3cret@h:1\n")

        XCTAssertEqual(try mode(of: url), 0o600)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8),
                       "DEVDECK_PROXY_URL=http://dev:s3cret@h:1\n",
                       "O_TRUNC: no remnant of the longer previous contents")
    }

    func testTheDirectoryIsCreatedOwnerOnly() throws {
        let url = dir.appendingPathComponent(".config/devdeck/proxy.env")

        LiveProxyEnvFile(url: url).write("DEVDECK_PROXY_URL=http://h:1\n")

        XCTAssertEqual(try mode(of: url.deletingLastPathComponent()), 0o700,
                       "nobody else needs to list or traverse a directory holding a password")
    }

    func testRemoveDeletesTheFileAndToleratesItBeingAbsent() throws {
        let url = dir.appendingPathComponent(".config/devdeck/proxy.env")
        let writer = LiveProxyEnvFile(url: url)
        writer.write("DEVDECK_PROXY_URL=http://h:1\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        writer.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        writer.remove()   // already gone is the end state we wanted — must not be treated as an error
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
