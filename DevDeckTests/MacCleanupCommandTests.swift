import XCTest
@testable import DevDeck

/// The deletion command: one step per confirmed path, each re-checking in the shell what the
/// guard checked in Swift, quoting every path as one word.
final class MacCleanupCommandTests: XCTestCase {
    private func candidate(_ path: String, _ category: DiskCategory) -> DiskCandidate {
        DiskCandidate(path: path, category: category, bytes: 1, newestModification: 0)
    }

    func testARustTargetIsRemovedOnlyWhileItsCargoTomlIsStillNextToIt() {
        XCTAssertEqual(CleanupCommands.removalStep(candidate("/Users/u/work/p/target", .rustTarget)), """
        echo '→ /Users/u/work/p/target'
        if [ -d '/Users/u/work/p/target' ] && [ ! -L '/Users/u/work/p/target' ] && [ -f '/Users/u/work/p/Cargo.toml' ]; \
        then rm -rf -- '/Users/u/work/p/target' || rc=1; else echo 'skipped: no longer what the scan found'; rc=1; fi
        """)
    }

    func testNodeModulesNeedsItsPackageJson() {
        let step = CleanupCommands.removalStep(candidate("/Users/u/web/node_modules", .nodeModules))
        XCTAssertTrue(step.contains("[ -f '/Users/u/web/package.json' ]"), step)
        XCTAssertTrue(step.contains("rm -rf -- '/Users/u/web/node_modules'"), step)
    }

    func testACacheIsEmptiedAndItsFolderKept() {
        let step = CleanupCommands.removalStep(candidate("/Users/u/Library/Caches", .libraryCaches))
        XCTAssertTrue(step.contains("find '/Users/u/Library/Caches' -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"), step)
        XCTAssertFalse(step.contains("rm -rf -- '/Users/u/Library/Caches'"), "the folder itself stays")
    }

    func testGoModulesGoThroughGoCleanOnlyWhenGOMODCACHEIsThatPath() {
        let step = CleanupCommands.removalStep(candidate("/Users/u/go/pkg/mod", .goModules))
        XCTAssertTrue(step.contains("[ \"$(go env GOMODCACHE 2>/dev/null)\" = '/Users/u/go/pkg/mod' ]"), step)
        XCTAssertTrue(step.contains("then go clean -modcache || rc=1;"), step)
        XCTAssertFalse(step.contains("rm -rf"), "module files are read-only; go clean handles that")
    }

    func testAQuoteOrSpaceInAPathStaysInsideOneWord() {
        let step = CleanupCommands.removalStep(candidate("/Users/u/it's here/target", .rustTarget))
        XCTAssertTrue(step.contains("rm -rf -- '/Users/u/it'\\''s here/target'"), step)
        XCTAssertTrue(step.contains("[ -f '/Users/u/it'\\''s here/Cargo.toml' ]"), step)
    }

    func testEveryStepRunsAndTheExitCodeSaysWhetherAllDid() {
        let command = CleanupCommands.removeMacFiles([candidate("/Users/u/a/target", .rustTarget),
                                                      candidate("/Users/u/.cache", .userCache)])
        let lines = command.command.components(separatedBy: "\n")
        XCTAssertEqual(lines.first, "rc=0")
        XCTAssertEqual(lines.last, "exit $rc")
        XCTAssertEqual(lines.filter { $0.hasPrefix("if ") }.count, 2)
        XCTAssertFalse(command.command.contains("set -e"), "a failed step must not stop the others")
        XCTAssertEqual(command.id, CleanupCommands.macFilesID)
        XCTAssertTrue(CleanupCommands.allIDs.contains(CleanupCommands.macFilesID), "it locks the page like the others")
        XCTAssertFalse(command.isDaemon)
        XCTAssertFalse(command.needsSudo)
    }

    /// The real shell, on a throwaway tree in the temp folder: the step deletes a build directory,
    /// skips one that lost its Cargo.toml, and never follows a link swapped in for one.
    func testTheStepsInARealShell() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("mac-cleanup-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let fm = FileManager.default
        try fm.createDirectory(atPath: "\(base)/keep me", withIntermediateDirectories: true)
        fm.createFile(atPath: "\(base)/keep me/precious", contents: Data("x".utf8))
        for project in ["ok", "gone", "swapped"] {
            try fm.createDirectory(atPath: "\(base)/\(project)/target/debug", withIntermediateDirectories: true)
            fm.createFile(atPath: "\(base)/\(project)/Cargo.toml", contents: Data())
            fm.createFile(atPath: "\(base)/\(project)/target/debug/x", contents: Data("x".utf8))
        }
        try fm.removeItem(atPath: "\(base)/gone/Cargo.toml")
        try fm.removeItem(atPath: "\(base)/swapped/target")
        try fm.createSymbolicLink(atPath: "\(base)/swapped/target", withDestinationPath: "\(base)/keep me")

        let command = CleanupCommands.removeMacFiles(["ok", "gone", "swapped"].map {
            candidate("\(base)/\($0)/target", .rustTarget)
        })
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", command.command]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        XCTAssertEqual(process.terminationStatus, 1, "two steps were skipped")
        XCTAssertFalse(fm.fileExists(atPath: "\(base)/ok/target"))
        XCTAssertTrue(fm.fileExists(atPath: "\(base)/gone/target/debug/x"))
        XCTAssertTrue(fm.fileExists(atPath: "\(base)/keep me/precious"), "a link is never followed")
    }
}
