import XCTest
@testable import DevDeck

/// Every rule a path must pass right before it is deleted — each test breaks exactly one.
final class DeletionGuardTests: XCTestCase {
    private let home = "/h"

    private func project(_ fs: FakeDirectoryReader, _ dir: String = "/h/work/p") {
        fs.file("\(dir)/Cargo.toml", bytes: 1)
        fs.file("\(dir)/target/debug/.cargo-lock", bytes: 0)
        fs.file("\(dir)/target/debug/x", bytes: 10)
    }

    private func target(_ path: String = "/h/work/p/target") -> DiskCandidate {
        DiskCandidate(path: path, category: .rustTarget, bytes: 10, newestModification: 0)
    }

    private func check(_ inspector: FakeDeletionInspector, _ candidate: DiskCandidate) -> DeletionRejection? {
        DeletionGuard(inspector: inspector, root: home).check(candidate)
    }

    func testAnUntouchedBuildDirectoryPasses() {
        let fs = FakeDirectoryReader(root: home)
        project(fs)
        XCTAssertNil(check(FakeDeletionInspector(fs), target()))
    }

    func testTheHomeFolderTheRootAndAnythingOutsideNeverPass() {
        let fs = FakeDirectoryReader(root: home)
        fs.dir("/other/target")
        let inspector = FakeDeletionInspector(fs)
        for path in ["/h", "/", "/other/target", "/h/../other/target", "/h/./work/p/target", "/h/work//p/target", "/h/"] {
            XCTAssertEqual(check(inspector, target(path)), .outsideHome, path)
        }
    }

    func testAFixedCategoryMustBeExactlyAtItsPath() {
        let fs = FakeDirectoryReader(root: home)
        fs.dir("/h/Library/Caches")
        fs.dir("/h/Library")
        let inspector = FakeDeletionInspector(fs)
        XCTAssertNil(check(inspector, DiskCandidate(path: "/h/Library/Caches", category: .libraryCaches, bytes: 1, newestModification: 0)))
        XCTAssertEqual(check(inspector, DiskCandidate(path: "/h/Library", category: .libraryCaches, bytes: 1, newestModification: 0)),
                       .noLongerMatches)
    }

    func testAProjectCategoryInAToolOwnedPlaceIsRejected() {
        let fs = FakeDirectoryReader(root: home)
        project(fs, "/h/.cargo/git/checkouts/dep")
        XCTAssertEqual(check(FakeDeletionInspector(fs), target("/h/.cargo/git/checkouts/dep/target")), .noLongerMatches)
    }

    func testAPathThatIsGoneIsRejected() {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/work/p/Cargo.toml", bytes: 1)
        XCTAssertEqual(check(FakeDeletionInspector(fs), target()), .missing)
    }

    func testASymlinkInPlaceOfTheDirectoryIsRejected() {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/work/p/Cargo.toml", bytes: 1)
        fs.symlink("/h/work/p/target")
        XCTAssertEqual(check(FakeDeletionInspector(fs), target()), .symlink)
    }

    func testAFileInPlaceOfTheDirectoryIsRejected() {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/work/p/Cargo.toml", bytes: 1)
        fs.file("/h/work/p/target", bytes: 1)
        XCTAssertEqual(check(FakeDeletionInspector(fs), target()), .notADirectory)
    }

    func testASymlinkedAncestorIsRejected() {
        let fs = FakeDirectoryReader(root: home)
        project(fs)
        let inspector = FakeDeletionInspector(fs)
        inspector.resolved["/h/work/p/target"] = "/Volumes/ext/p/target"   // ~/work is a link elsewhere
        XCTAssertEqual(check(inspector, target()), .symlinkedAncestor)
    }

    func testAnotherVolumeIsRejected() {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/work/p/Cargo.toml", bytes: 1)
        fs.dir("/h/work/p/target", device: 9)
        XCTAssertEqual(check(FakeDeletionInspector(fs), target()), .otherVolume)
    }

    func testAMissingManifestOrAProjectInsideIsRejected() {
        let noManifest = FakeDirectoryReader(root: home)
        noManifest.file("/h/work/p/target/x", bytes: 1)
        XCTAssertEqual(check(FakeDeletionInspector(noManifest), target()), .noLongerMatches)

        let crate = FakeDirectoryReader(root: home)
        project(crate)
        crate.file("/h/work/p/target/Cargo.toml", bytes: 1)
        XCTAssertEqual(check(FakeDeletionInspector(crate), target()), .noLongerMatches)

        let upper = FakeDirectoryReader(root: home)
        project(upper)
        upper.dir("/h/work/p/target/.Git")
        XCTAssertEqual(check(FakeDeletionInspector(upper), target()), .noLongerMatches, "APFS ignores case")

        let repo = FakeDirectoryReader(root: home)
        repo.file("/h/web/package.json", bytes: 1)
        repo.dir("/h/web/node_modules/.git")
        XCTAssertEqual(check(FakeDeletionInspector(repo),
                             DiskCandidate(path: "/h/web/node_modules", category: .nodeModules, bytes: 1, newestModification: 0)),
                       .noLongerMatches)
    }

    func testAHeldCargoLockMeansABuildIsRunning() {
        let fs = FakeDirectoryReader(root: home)
        project(fs)
        let inspector = FakeDeletionInspector(fs)
        inspector.heldLocks = ["/h/work/p/target/debug/.cargo-lock"]
        XCTAssertEqual(check(inspector, target()), .buildRunning)
    }

    func testPlainAbsolutePaths() {
        XCTAssertTrue(DeletionGuard.isPlainAbsolute("/a/b"))
        for bad in ["a/b", "/", "/a/", "/a//b", "/a/./b", "/a/../b", ""] {
            XCTAssertFalse(DeletionGuard.isPlainAbsolute(bad), bad)
        }
    }

    /// The live lock probe against a real `flock` — on a temp file, never in the user's home.
    func testLiveLockProbeSeesAHeldFlock() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lock-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: url.path, contents: Data())
        defer { try? FileManager.default.removeItem(at: url) }
        let inspector = LiveDeletionInspector()
        XCTAssertFalse(inspector.isLockHeld(url.path))

        let fd = open(url.path, O_RDONLY)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)
        XCTAssertTrue(inspector.isLockHeld(url.path))
    }
}
