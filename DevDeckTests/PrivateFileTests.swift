import XCTest
@testable import DevDeck

/// The one place that decides who may read what DevDeck writes.
///
/// These assert modes on a real temp path rather than mocking the filesystem: the whole point of
/// the type is the number the kernel ends up storing, and a fake would only re-state the intent.
final class PrivateFileTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("devdeck-privatefile-\(UUID().uuidString)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func mode(of url: URL) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
    }

    // MARK: - Directories

    func testMakeDirectoryCreatesItOwnerOnly() throws {
        let dir = root.appendingPathComponent("nested/DevDeck")
        try PrivateFile.makeDirectory(at: dir)

        XCTAssertEqual(try mode(of: dir), 0o700)
    }

    func testMakeDirectoryTightensAnExistingLooseOne() throws {
        // The migration case: every install created before this shipped has a 0755 directory.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(try mode(of: root), 0o755)

        try PrivateFile.makeDirectory(at: root)

        XCTAssertEqual(try mode(of: root), 0o700, "an existing directory must be tightened, not skipped")
    }

    // MARK: - Files

    func testRestrictTightensALooseFile() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("config.json")
        FileManager.default.createFile(atPath: file.path, contents: Data("{}".utf8),
                                       attributes: [.posixPermissions: 0o644])

        PrivateFile.restrict(file)

        XCTAssertEqual(try mode(of: file), 0o600)
    }

    func testRestrictOnAMissingFileIsHarmless() throws {
        // Callers use it right after a write that may have failed, and on paths that legitimately
        // don't exist yet (a log that has never rotated).
        PrivateFile.restrict(root.appendingPathComponent("absent"))
    }

    // MARK: - LivePrivateFile

    func testWriteCreatesTheDirectoryAndTheFileOwnerOnly() throws {
        let file = root.appendingPathComponent("devdeck/gost.json")

        XCTAssertTrue(LivePrivateFile(url: file).write(#"{"services":[]}"#))

        XCTAssertEqual(try mode(of: file), 0o600)
        XCTAssertEqual(try mode(of: file.deletingLastPathComponent()), 0o700)
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), #"{"services":[]}"#)
    }

    func testWriteTightensAFileLeftLooseByAnOlderBuild() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("proxy.env")
        FileManager.default.createFile(atPath: file.path, contents: Data("old".utf8),
                                       attributes: [.posixPermissions: 0o644])

        // O_CREAT's mode argument is ignored for an existing file, so this only passes because of
        // the explicit fchmod — and it runs before any byte is written.
        XCTAssertTrue(LivePrivateFile(url: file).write("new"))

        XCTAssertEqual(try mode(of: file), 0o600)
    }

    func testWriteRefusesToFollowASymlink() throws {
        // Without O_NOFOLLOW, anything that can plant a symlink at our path redirects the write —
        // and these files can hold a proxy password.
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let target = root.appendingPathComponent("victim")
        FileManager.default.createFile(atPath: target.path, contents: Data("precious".utf8))
        let link = root.appendingPathComponent("proxy.env")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        XCTAssertFalse(LivePrivateFile(url: link).write("attacker-controlled"))

        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "precious",
                       "the symlink target must be untouched")
    }

    func testRemoveReportsSuccessWhenAlreadyAbsent() {
        // "Gone" is the end state the caller wanted; treating an absent file as a failure would
        // make the manager retry a removal forever.
        XCTAssertTrue(LivePrivateFile(url: root.appendingPathComponent("never-existed")).remove())
    }

    func testRemoveDeletesTheFile() throws {
        let file = root.appendingPathComponent("gost.json")
        XCTAssertTrue(LivePrivateFile(url: file).write("x"))

        XCTAssertTrue(LivePrivateFile(url: file).remove())

        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
    }
}
