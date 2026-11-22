import XCTest
@testable import DevDeck

/// The deletion command: one anchored step per confirmed path, each repeating the guard in the
/// shell when it runs, quoting every path as one word.
final class MacCleanupCommandTests: XCTestCase {
    private func candidate(_ path: String, _ category: DiskCategory) -> DiskCandidate {
        DiskCandidate(path: path, category: category, bytes: 1, newestModification: 0)
    }

    private func step(_ candidate: DiskCandidate) -> String {
        CleanupCommands.removalStep(candidate, device: 16_777_233)
    }

    func testARustTargetIsRemovedByNameFromItsVerifiedParent() {
        let step = step(candidate("/Users/u/work/p/target", .rustTarget))
        XCTAssertTrue(step.contains("cd -P -- '/Users/u/work/p' 2>/dev/null && p=$(pwd -P && echo .) && [ \"${p%??}\" = '/Users/u/work/p' ]"), step)
        XCTAssertTrue(step.contains("[ \"$(/usr/bin/stat -f %d .)\" = '16777233' ]"), "still the confirmed volume")
        XCTAssertTrue(step.contains("/usr/bin/lockf -kns -t 0"), "cargo's lock is checked when the step runs")
        XCTAssertTrue(step.contains("[ -f 'Cargo.toml' ]"), step)
        XCTAssertTrue(step.contains("[ ! -L 'target' ]"), step)
        XCTAssertTrue(step.contains("[ ! -e 'target'/.git ]"), "a checkout moved in is not deleted")
        XCTAssertTrue(step.contains("[ ! -e 'target'/Cargo.toml ]"), "nor a crate called target")
        XCTAssertTrue(step.contains("[ \"$(/usr/bin/stat -f %d 'target')\" = '16777233' ]"), "same volume as home")
        XCTAssertTrue(step.contains("then /bin/rm -rfx -- 'target';"), "relative to the anchor, never across a mount")
        XCTAssertFalse(step.contains("rm -rfx -- '/Users"), "never by absolute path")
    }

    func testNodeModulesNeedsItsPackageJson() {
        let step = step(candidate("/Users/u/web/node_modules", .nodeModules))
        XCTAssertTrue(step.contains("[ -f 'package.json' ]"), step)
        XCTAssertTrue(step.contains("/bin/rm -rfx -- 'node_modules'"), step)
        XCTAssertFalse(step.contains("Cargo.toml"), step)
    }

    func testACacheIsEmptiedEntryByEntryOnItsOwnVolumeAndItsFolderKept() {
        let step = step(candidate("/Users/u/Library/Caches", .libraryCaches))
        XCTAssertTrue(step.contains("cd -P -- '/Users/u/Library/Caches'"), step)
        XCTAssertTrue(step.contains("for e in ./*(DN)"), step)
        XCTAssertTrue(step.contains("elif [ \"$d\" = '16777233' ]; then /bin/rm -rfx -- \"$e\""), "a mount inside is never handed to rm")
        XCTAssertTrue(step.contains("[ -r . ] ||"), "an unlistable folder fails instead of looking emptied")
        XCTAssertFalse(step.contains("'/Users/u/Library/Caches';"), "the folder itself stays")
    }

    func testGoModulesArePinnedToTheConfirmedPathAndFlags() {
        let step = step(candidate("/Users/u/go/pkg/mod", .goModules))
        XCTAssertTrue(step.contains("g=$(go env GOMODCACHE && echo .) && [ \"${g%??}\" = '/Users/u/go/pkg/mod' ]"),
                      "only when Go's own cache is this folder")
        XCTAssertTrue(step.contains("GOMODCACHE='/Users/u/go/pkg/mod' GOFLAGS=-modcacherw go clean -modcache"), step)
        XCTAssertFalse(step.contains("rm -rf"), "module files are read-only; go clean handles that")
    }

    func testAQuoteOrSpaceInAPathStaysInsideOneWord() {
        let step = step(candidate("/Users/u/it's here/target", .rustTarget))
        XCTAssertTrue(step.contains("cd -P -- '/Users/u/it'\\''s here'"), step)
    }

    func testEveryStepRunsAndTheExitCodeSaysWhetherAllDid() {
        let command = CleanupCommands.removeMacFiles([candidate("/Users/u/a/target", .rustTarget),
                                                      candidate("/Users/u/.cache", .userCache)],
                                                     device: 1, skipped: [("/Users/u/b/target", "a cargo build is running")])
        let lines = command.command.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "rc=0")
        XCTAssertEqual(lines[1], "echo 'skipped: /Users/u/b/target — a cargo build is running'",
                       "a path the last check turned away is named in the log")
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
    private var device: UInt64 = 0
    private let fm = FileManager.default

    override func setUpWithError() throws {
        // The temp folder sits behind the /var → /private/var link; the anchor compares real paths.
        let raw = fm.temporaryDirectory.appendingPathComponent("mac-cleanup-\(UUID().uuidString)").path
        try fm.createDirectory(atPath: raw, withIntermediateDirectories: true)
        base = try XCTUnwrap(LiveDeletionInspector().realPath(raw))
        device = try XCTUnwrap(LiveDirectoryReader().entry(at: base)).device
    }

    override func tearDown() {
        if !base.isEmpty { try? fm.removeItem(atPath: base) }
    }

    private func project(_ dir: String) throws {
        try fm.createDirectory(atPath: "\(base)/\(dir)/target/debug", withIntermediateDirectories: true)
        fm.createFile(atPath: "\(base)/\(dir)/Cargo.toml", contents: Data())
        fm.createFile(atPath: "\(base)/\(dir)/target/debug/x", contents: Data("x".utf8))
    }

    private func run(_ candidates: [DiskCandidate], device: UInt64? = nil) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", CleanupCommands.removeMacFiles(candidates, device: device ?? self.device).command]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }

    func testTheShellDeletesOnlyWhatStillMatches() throws {
        try fm.createDirectory(atPath: "\(base)/keep me", withIntermediateDirectories: true)
        fm.createFile(atPath: "\(base)/keep me/precious", contents: Data("x".utf8))
        for dir in ["ok", "it's ok", "gone", "swapped", "repo", "last"] { try project(dir) }
        try fm.removeItem(atPath: "\(base)/gone/Cargo.toml")
        try fm.removeItem(atPath: "\(base)/swapped/target")
        try fm.createSymbolicLink(atPath: "\(base)/swapped/target", withDestinationPath: "\(base)/keep me")
        try fm.createDirectory(atPath: "\(base)/repo/target/.GIT", withIntermediateDirectories: true)

        // "last" comes after every rejected one: a failed step must not stop the ones after it.
        let status = try run(["ok", "it's ok", "gone", "swapped", "repo", "last"].map { candidate("\(base)/\($0)/target", .rustTarget) })

        XCTAssertEqual(status, 1, "three steps were skipped")
        XCTAssertFalse(fm.fileExists(atPath: "\(base)/last/target"), "the step after the failures still ran")
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

    func testABuildHoldingCargosLockIsSkippedWhenTheStepRuns() throws {
        try project("busy")
        fm.createFile(atPath: "\(base)/busy/target/debug/.cargo-lock", contents: Data())
        let fd = open("\(base)/busy/target/debug/.cargo-lock", O_RDONLY)
        defer { close(fd) }
        XCTAssertEqual(flock(fd, LOCK_EX), 0)

        XCTAssertEqual(try run([candidate("\(base)/busy/target", .rustTarget)]), 1)
        XCTAssertTrue(fm.fileExists(atPath: "\(base)/busy/target/debug/x"))
        XCTAssertTrue(fm.fileExists(atPath: "\(base)/busy/target/debug/.cargo-lock"), "lockf -k keeps cargo's file")
    }

    /// A volume mounted over the path since the check looks like another device: nothing goes.
    func testAnotherVolumeThanTheConfirmedOneIsLeftAlone() throws {
        try project("p")
        fm.createFile(atPath: "\(base)/c/blob", contents: nil)
        try fm.createDirectory(atPath: "\(base)/c/inner", withIntermediateDirectories: true)

        XCTAssertEqual(try run([candidate("\(base)/p/target", .rustTarget), candidate("\(base)/c", .userCache)],
                               device: device &+ 1), 1)
        XCTAssertTrue(fm.fileExists(atPath: "\(base)/p/target/debug/x"))
        XCTAssertTrue(fm.fileExists(atPath: "\(base)/c/inner"))
    }

    func testAnUnlistableCacheFailsInsteadOfLookingEmptied() throws {
        try fm.createDirectory(atPath: "\(base)/c/inner", withIntermediateDirectories: true)
        try fm.setAttributes([.posixPermissions: 0o300], ofItemAtPath: "\(base)/c")   // search, no read
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: "\(base)/c") }

        XCTAssertEqual(try run([candidate("\(base)/c", .userCache)]), 1)
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
