import XCTest
@testable import DevDeck

/// The walk over the home folder, on an in-memory tree: what is counted, what is skipped, which
/// directories become deletion candidates and which never may.
final class DiskScannerTests: XCTestCase {
    private let home = "/h"
    private let mb: UInt64 = 1_048_576
    private let gb: UInt64 = 1_073_741_824

    private func scan(_ fs: FakeDirectoryReader, cancel: @escaping () -> Bool = { false }) throws -> DiskScanResult {
        try DiskScanner(reader: fs, root: home).scan(now: Date(timeIntervalSince1970: 0), isCancelled: cancel)
    }

    private func candidate(_ result: DiskScanResult, _ path: String) -> DiskCandidate? {
        result.candidates.first { $0.path == path }
    }

    // MARK: sizes

    func testAddsUpAllocatedBytesAndKeepsBigDirectoriesInTheTree() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/work/big/a.bin", bytes: 3 * gb)
        fs.file("/h/work/small/b.txt", bytes: 2 * mb)
        fs.file("/h/notes.txt", bytes: 1 * mb)

        let result = try scan(fs)

        XCTAssertEqual(result.tree.bytes, 3 * gb + 3 * mb)
        XCTAssertEqual(result.fileCount, 3)
        let work = try XCTUnwrap(result.tree.children.first { $0.name == "work" })
        XCTAssertEqual(work.children.map(\.name), ["big"], "a 2 MB directory is folded into its parent's other")
        XCTAssertEqual(work.otherBytes, 2 * mb)
    }

    func testAHardLinkedFileIsCountedOnce() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/a/blob", bytes: gb, inode: 7, links: 2)
        fs.file("/h/b/blob", bytes: gb, inode: 7, links: 2)

        XCTAssertEqual(try scan(fs).tree.bytes, gb)
    }

    func testASymlinkIsNeverFollowed() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.symlink("/h/link")
        fs.dir("/h/link/inside")   // would only be reachable through the link

        _ = try scan(fs)

        XCTAssertFalse(fs.listed.contains("/h/link"))
    }

    func testAnotherVolumeIsNotEntered() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.dir("/h/mnt", device: 2)
        fs.file("/h/mnt/huge", bytes: 500 * gb)

        let result = try scan(fs)

        XCTAssertFalse(fs.listed.contains("/h/mnt"))
        XCTAssertEqual(result.tree.bytes, 0)
    }

    func testAnUnreadableDirectoryMakesTheResultPartialWithoutStopping() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/Library/Mail/x", bytes: gb)
        fs.deny("/h/Library/Mail")
        fs.file("/h/work/y", bytes: gb)

        let result = try scan(fs)

        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.unreadable, ["/h/Library/Mail"])
        XCTAssertEqual(result.tree.bytes, gb, "what could be read is still counted")
    }

    func testProtectedFoldersAreNotEvenListed() throws {
        let fs = FakeDirectoryReader(root: home)
        for relative in DiskScanner.protectedRelativePaths { fs.file("/h/\(relative)/f", bytes: gb) }
        fs.file("/h/Library/Caches/c", bytes: gb)

        let result = try scan(fs)

        for relative in DiskScanner.protectedRelativePaths {
            XCTAssertFalse(fs.listed.contains("/h/\(relative)"), "\(relative) would raise a macOS consent prompt")
        }
        XCTAssertEqual(Set(result.skipped), Set(DiskScanner.protectedRelativePaths.map { "/h/\($0)" }))
        XCTAssertFalse(result.isPartial, "skipping on purpose is not a read failure")
        XCTAssertEqual(result.tree.bytes, gb)
    }

    func testCancellationStopsTheWalk() {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/a/b/c", bytes: 1)
        var asked = 0
        XCTAssertThrowsError(try scan(fs) { asked += 1; return asked > 1 })
        XCTAssertLessThanOrEqual(fs.listed.count, 1)
    }

    func testReportsProgressAtEachTopLevelFolder() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/a/x", bytes: 1)
        fs.file("/h/b/y", bytes: 1)
        var seen: [String] = []
        _ = try DiskScanner(reader: fs, root: home).scan(progress: { if let c = $0.current { seen.append(c) } })
        XCTAssertEqual(Set(seen), ["a", "b"])
    }

    // MARK: categories

    func testRecognisesARustTargetNextToCargoTomlWithItsNewestModification() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/work/grount/Cargo.toml", bytes: 1)
        fs.dir("/h/work/grount/target", modified: 100)
        fs.file("/h/work/grount/target/debug/deps/libx.rlib", bytes: 2 * gb, modified: 5_000)

        let result = try scan(fs)

        let target = try XCTUnwrap(candidate(result, "/h/work/grount/target"))
        XCTAssertEqual(target.category, .rustTarget)
        XCTAssertEqual(target.bytes, 2 * gb)
        XCTAssertEqual(target.newestModification, 5_000, "a build touches files deep inside, not the directory")
    }

    func testATargetWithoutCargoTomlOrThatIsAProjectItselfIsNotOffered() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/work/java/target/classes/a.class", bytes: gb)          // Maven, no Cargo.toml
        fs.file("/h/work/ws/Cargo.toml", bytes: 1)
        fs.file("/h/work/ws/target/Cargo.toml", bytes: 1)                   // a crate called "target"
        fs.file("/h/work/ws/target/src/lib.rs", bytes: gb)
        fs.file("/h/work/repo/Cargo.toml", bytes: 1)
        fs.dir("/h/work/repo/target/.git")
        fs.file("/h/work/repo/target/x", bytes: gb)

        XCTAssertTrue(try scan(fs).candidates.isEmpty)
    }

    func testOnlyTheOutermostNodeModulesIsOffered() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/web/package.json", bytes: 1)
        fs.file("/h/web/node_modules/dep/package.json", bytes: 1)
        fs.file("/h/web/node_modules/dep/node_modules/inner/i.js", bytes: gb)

        let result = try scan(fs)

        XCTAssertEqual(result.candidates.map(\.path), ["/h/web/node_modules"])
        XCTAssertEqual(result.candidates.first?.category, .nodeModules)
    }

    func testToolOwnedPlacesOfferNoProjectCategories() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/.vscode/extensions/ext/package.json", bytes: 1)
        fs.file("/h/.vscode/extensions/ext/node_modules/m.js", bytes: gb)
        fs.file("/h/.cargo/git/checkouts/dep/Cargo.toml", bytes: 1)
        fs.file("/h/.cargo/git/checkouts/dep/target/t", bytes: gb)
        fs.file("/h/Library/Application Support/App/package.json", bytes: 1)
        fs.file("/h/Library/Application Support/App/node_modules/n.js", bytes: gb)

        XCTAssertTrue(try scan(fs).candidates.isEmpty)
    }

    func testFixedCategoriesAreFoundAtTheirPathsAndNothingNestedInsideThem() throws {
        let fs = FakeDirectoryReader(root: home)
        for category in DiskCategory.fixedCategories {
            fs.file("/h/\(category.fixedRelativePath!)/blob", bytes: gb)
        }
        fs.file("/h/.cache/proj/Cargo.toml", bytes: 1)
        fs.file("/h/.cache/proj/target/t", bytes: gb)

        let result = try scan(fs)

        XCTAssertEqual(Set(result.candidates.map(\.category)), Set(DiskCategory.fixedCategories))
        XCTAssertEqual(candidate(result, "/h/.cache")?.bytes, 2 * gb + 1, "nested target is measured, not offered")
        XCTAssertNil(candidate(result, "/h/.cache/proj/target"))
    }

    func testSmallCandidatesAreSummedIntoOneLine() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/a/package.json", bytes: 1)
        fs.file("/h/a/node_modules/x", bytes: 10 * mb)
        fs.file("/h/b/package.json", bytes: 1)
        fs.file("/h/b/node_modules/x", bytes: 20 * mb)
        fs.file("/h/c/package.json", bytes: 1)
        fs.file("/h/c/node_modules/x", bytes: gb)

        let result = try scan(fs)

        XCTAssertEqual(result.candidates.map(\.path), ["/h/c/node_modules"])
        XCTAssertEqual(result.smallCandidateCount, 2)
        XCTAssertEqual(result.smallCandidateBytes, 30 * mb)
    }

    func testCandidatesComeBiggestFirstAndAreMarkedInTheTree() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/w/a/Cargo.toml", bytes: 1)
        fs.file("/h/w/a/target/t", bytes: gb)
        fs.file("/h/w/b/Cargo.toml", bytes: 1)
        fs.file("/h/w/b/target/t", bytes: 3 * gb)

        let result = try scan(fs)

        XCTAssertEqual(result.candidates.map(\.path), ["/h/w/b/target", "/h/w/a/target"])
        let b = result.tree.children.first { $0.name == "w" }?.children.first { $0.name == "b" }
        XCTAssertEqual(b?.children.first?.category, .rustTarget)
    }

    // MARK: after a deletion

    func testForgettingRemovedPathsTakesTheirBytesOutOfTheTree() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/w/a/Cargo.toml", bytes: 1)
        fs.file("/h/w/a/target/t", bytes: 2 * gb)
        fs.file("/h/Library/Caches/c/blob", bytes: gb)
        var result = try scan(fs)

        result.forgetRemoved(["/h/w/a/target", "/h/Library/Caches"], stillThere: { _ in false })

        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.tree.bytes, 1)
        let w = result.tree.children.first { $0.name == "w" }
        XCTAssertNil(w?.children.first?.children.first { $0.name == "target" })
    }

    func testAPathThatSurvivedTheDeletionStays() throws {
        let fs = FakeDirectoryReader(root: home)
        fs.file("/h/w/a/Cargo.toml", bytes: 1)
        fs.file("/h/w/a/target/t", bytes: 2 * gb)
        var result = try scan(fs)

        result.forgetRemoved(["/h/w/a/target"], stillThere: { _ in true })

        XCTAssertEqual(result.candidates.count, 1)
        XCTAssertEqual(result.tree.bytes, 2 * gb + 1)
    }
}
