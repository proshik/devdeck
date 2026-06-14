import XCTest
@testable import DevDeck

final class TouchIDSudoTests: XCTestCase {
    func testHasPamTidDetectsUncommentedAuthLine() {
        let enabled = """
        # sudo_local: local config file which survives system update
        auth       sufficient     pam_tid.so
        """
        XCTAssertTrue(TouchIDSudo.hasPamTid(enabled))
    }

    func testHasPamTidIgnoresCommentedAndForeignLines() {
        XCTAssertFalse(TouchIDSudo.hasPamTid("#auth       sufficient     pam_tid.so"))
        XCTAssertFalse(TouchIDSudo.hasPamTid("   # auth sufficient pam_tid.so"))
        XCTAssertFalse(TouchIDSudo.hasPamTid("account required pam_tid.so"))
        XCTAssertFalse(TouchIDSudo.hasPamTid(""))
    }

    func testIsEnabledReadsFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("sudo_local")

        XCTAssertFalse(TouchIDSudo.isEnabled(sudoLocalPath: file.path), "no file → disabled")

        try "auth sufficient pam_tid.so".write(to: file, atomically: true, encoding: .utf8)
        XCTAssertTrue(TouchIDSudo.isEnabled(sudoLocalPath: file.path))
    }

    func testIsAuthFailureSignature() {
        // Auth failure: non-zero exit code, nothing was executed, sudo marker in stderr.
        XCTAssertTrue(SudoCommandRunner.isAuthFailure(
            exitCode: 1, sawStdout: false,
            stderrTail: ["sudo: a terminal is required to read the password; either use the -S option…",
                         "sudo: a password is required"]))
        // The command produced output → this is its own failure, not an auth failure.
        XCTAssertFalse(SudoCommandRunner.isAuthFailure(
            exitCode: 1, sawStdout: true, stderrTail: ["sudo: a password is required"]))
        // Regular command failure with no sudo markers.
        XCTAssertFalse(SudoCommandRunner.isAuthFailure(
            exitCode: 2, sawStdout: false, stderrTail: ["purge: failed"]))
        // Success — not an auth failure.
        XCTAssertFalse(SudoCommandRunner.isAuthFailure(exitCode: 0, sawStdout: false, stderrTail: []))
    }
}
