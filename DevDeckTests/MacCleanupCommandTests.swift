import XCTest
@testable import DevDeck

/// The deletion command: one anchored step per confirmed path, each repeating the guard in the
/// shell when it runs, quoting every path as one word.
final class MacCleanupCommandTests: XCTestCase {
    private func candidate(_ path: String, _ category: DiskCategory) -> DiskCandidate {
        DiskCandidate(path: path, category: category, bytes: 1, newestModification: 0)
    }

    func testARustTargetIsRemovedByNameFromItsVerifiedParent() {
        let step = CleanupCommands.removalStep(candidate("/Users/u/work/p/target", .rustTarget))
        XCTAssertTrue(step.contains("cd -P -- '/Users/u/work/p' 2>/dev/null && [ \"$(pwd -P)\" = '/Users/u/work/p' ]"), step)
        XCTAssertTrue(step.contains("[ -f 'Cargo.toml' ]"), step)
        XCTAssertTrue(step.contains("[ ! -L 'target' ]"), step)
        XCTAssertTrue(step.contains("[ ! -e 'target'/.git ]"), "a checkout moved in is not deleted")
        XCTAssertTrue(step.contains("[ ! -e 'target'/Cargo.toml ]"), "nor a crate called target")
        XCTAssertTrue(step.contains("/usr/bin/stat -f %d 'target'"), "same volume as its parent")
        XCTAssertTrue(step.contains("then /bin/rm -rfx -- 'target';"), "relative to the anchor, never across a mount")
        XCTAssertFalse(step.contains("rm -rfx -- '/Users"), "never by absolute path")
    }

    func testNodeModulesNeedsItsPackageJson() {
        let step = CleanupCommands.removalStep(candidate("/Users/u/web/node_modules", .nodeModules))
        XCTAssertTrue(step.contains("[ -f 'package.json' ]"), step)
        XCTAssertTrue(step.contains("/bin/rm -rfx -- 'node_modules'"), step)
        XCTAssertFalse(step.contains("Cargo.toml"), step)
    }

    func testACacheIsEmptiedEntryByEntryOnItsOwnVolumeAndItsFolderKept() {
        let step = CleanupCommands.removalStep(candidate("/Users/u/Library/Caches", .libraryCaches))
        XCTAssertTrue(step.contains("cd -P -- '/Users/u/Library/Caches'"), step)
        XCTAssertTrue(step.contains("for e in ./*(DN)"), step)
        XCTAssertTrue(step.contains("= \"$dev\" ]; then /bin/rm -rfx -- \"$e\""), "a mount inside is never handed to rm")
        XCTAssertFalse(step.contains("'/Users/u/Library/Caches';"), "the folder itself stays")
    }

    func testGoModulesArePinnedToTheConfirmedPathAndFlags() {
        let step = CleanupCommands.removalStep(candidate("/Users/u/go/pkg/mod", .goModules))
        XCTAssertTrue(step.contains("GOMODCACHE='/Users/u/go/pkg/mod' GOFLAGS=-modcacherw go clean -modcache"), step)
        XCTAssertFalse(step.contains("rm -rf"), "module files are read-only; go clean handles that")
    }

    func testAQuoteOrSpaceInAPathStaysInsideOneWord() {
        let step = CleanupCommands.removalStep(candidate("/Users/u/it's here/target", .rustTarget))
        XCTAssertTrue(step.contains("cd -P -- '/Users/u/it'\\''s here'"), step)
    }

    func testEveryStepRunsAndTheExitCodeSaysWhetherAllDid() {
        let command = CleanupCommands.removeMacFiles([candidate("/Users/u/a/target", .rustTarget),
                                                      candidate("/Users/u/.cache", .userCache)])
        let lines = command.command.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "rc=0")
        XCTAssertEqual(lines.last, "exit $rc")
        XCTAssertEqual(lines.filter { $0.hasPrefix("( ") && $0.hasSuffix(") || rc=1") }.count, 2,
                       "each step in its own subshell, a failure recorded and the next one run")
        XCTAssertEqual(command.id, CleanupCommands.macFilesID)
        XCTAssertTrue(CleanupCommands.allIDs.contains(CleanupCommands.macFilesID), "it locks the page like the others")
        XCTAssertFalse(command.isDaemon)
        XCTAssertFalse(command.needsSudo)
    }

    // MARK: - the real shell, on a throwaway tree in the temp folder

    private var base = ""
    private let fm = FileManager.default

    override func setUpWithError() throws {
        // The temp folder sits behind the /var → /private/var link; the anchor compares real paths.
        let raw = fm.temporaryDirectory.appendingPathComponent("mac-cleanup-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: raw, withIntermediateDirectories: true)
        base = try XCTUnwrap(LiveDeletionInspector().realPath(raw))
    }

    override func tearDown() {
        if !base.isEmpty { try? fm.removeItem(atPath: base) }
    }

    private func project(_ dir: String) throws {
        try fm.createDirectory(atPath: "\(base)/\(dir)/target/debug", withIntermediateDirectories: true)
        fm.createFile(atPath: "\(base)/\(dir)/Cargo.toml", contents: Data())
        fm.createFile(atPath: "\(base)/\(dir)/target/debug/x", contents: Data("x".utf8))
    }

    private func run(_ candidates: [DiskCandidate]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", CleanupCommands.removeMacFiles(candidates).command]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testTheShellDeletesOnlyWhatStillMatches() throws {
        try fm.createDirectory(atPath: "\(base)/keep me", withIntermediateDirectories: true)
        fm.createFile(atPath: "\(base)/keep me/precious", contents: Data("x".utf8))
        for dir in ["ok", "it's ok", "gone", "swapped", "repo"] { try project(dir) }
        try fm.removeItem(atPath: "\(base)/gone/Cargo.toml")
        try fm.removeItem(atPath: "\(base)/swapped/target")
        try fm.createSymbolicLink(atPath: "\(base)/swapped/target", withDestinationPath: "\(base)/keep me")
        try fm.createDirectory(atPath: "\(base)/repo/target/.GIT", withIntermediateDirectories: true)

        let status = try run(["ok", "it's ok", "gone", "swapped", "repo"].map { candidate("\(base)/\($0)/target", .rustTarget) })

        XCTAssertEqual(status, 1, "three steps were skipped")
        XCTAssertFalse(fm.fileExists(atPath: "\(base)/ok/target"))
        XCTAssertFalse(fm.fileExists(atPath: "\(base)/it's ok/target"))
        XCTAssertTrue(fm.fileExists(atPath: "\(base)/gone/target/debug/x"), "its Cargo.toml is gone")
        XCTAssertTrue(fm.fileExists(atPath: "\(base)/keep me/precious"), "a link is never followed")
        XCTAssertTrue(fm.fileExists(atPath: "\(base)/repo/target/debug/x"), ".GIT is .git on APFS")
    }

    /// The scan saw `~/work/p/target`; since then `work` became a link to somewhere else that
    /// holds a matching project. The anchor sees the real path differ and deletes nothing.
    func testAnAncestorSwappedForALinkIsNotFollowed() throws {
        try project("elsewhere/p")
        try fm.createSymbolicLink(atPath: "\(base)/work", withDestinationPath: "\(base)/elsewhere")

        XCTAssertEqual(try run([candidate("\(base)/work/p/target", .rustTarget)]), 1)
        XCTAssertTrue(fm.fileExists(atPath: "\(base)/elsewhere/p/target/debug/x"))
    }

    func testACacheIsEmptiedButALinkInsideIsRemovedNotFollowed() throws {
        try fm.createDirectory(atPath: "\(base)/keep", withIntermediateDirectories: true)
        fm.createFile(atPath: "\(base)/keep/precious", contents: Data("x".utf8))
        try fm.createDirectory(atPath: "\(base)/Caches/app", withIntermediateDirectories: true)
        fm.createFile(atPath: "\(base)/Caches/app/blob", contents: Data("x".utf8))
        fm.createFile(atPath: "\(base)/Caches/.hidden", contents: Data("x".utf8))
        try fm.createSymbolicLink(atPath: "\(base)/Caches/link", withDestinationPath: "\(base)/keep")

        XCTAssertEqual(try run([candidate("\(base)/Caches", .libraryCaches)]), 0)
        XCTAssertEqual(try fm.contentsOfDirectory(atPath: "\(base)/Caches"), [], "dot-files too")
        XCTAssertTrue(fm.fileExists(atPath: "\(base)/keep/precious"))
    }
}
