import XCTest
@testable import DevDeck

final class BuildDiagnosticsTests: XCTestCase {
    func testDetectsSignal9AsOOM() {
        let v = detectOOM(exitCode: 137, logTail: "")   // 128 + 9
        XCTAssertTrue(v.isOOM)
        let v2 = detectOOM(exitCode: 9, logTail: "")
        XCTAssertTrue(v2.isOOM)
        XCTAssertFalse(detectOOM(exitCode: 1, logTail: "error[E0277]").isOOM)
        XCTAssertFalse(detectOOM(exitCode: 0, logTail: "").isOOM)
    }

    func testExtractsCrateFromCouldNotCompile() {
        let tail = """
        error: could not compile `solana-runtime` (lib) due to 1 previous error
        """
        XCTAssertEqual(detectOOM(exitCode: 101, logTail: tail).crate, "solana-runtime")
    }

    func testOOMFromLogTextEvenWithGenericExit() {
        let tail = "rustc killed (signal: 9, SIGKILL: 9)\nerror: could not compile `heavy-crate`"
        let v = detectOOM(exitCode: 101, logTail: tail)
        XCTAssertTrue(v.isOOM, "signal: 9 in the log marks OOM even when the wrapper exit is 101")
        XCTAssertEqual(v.crate, "heavy-crate")
    }

    func testNoCrateNoFalsePositive() {
        let v = detectOOM(exitCode: 1, logTail: "warning: unused variable")
        XCTAssertFalse(v.isOOM)
        XCTAssertNil(v.crate)
    }

    func testAdviseJobsAppliesLimitOverTwoRule() {
        let gib: UInt64 = 1_073_741_824
        let a = adviseJobs(command: "just dev-build", env: [:], vmCpus: 6, limitBytes: 6 * gib)
        XCTAssertEqual(a.effectiveJobs, 6, "default -j = VM cores")
        XCTAssertEqual(a.advisedJobs, 3, "limit_GB / 2")
        XCTAssertTrue(a.overBudget)
    }

    func testAdviseJobsReadsExplicitFlagAndEnv() {
        let gib: UInt64 = 1_073_741_824
        XCTAssertEqual(adviseJobs(command: "cargo build -j 2", env: [:], vmCpus: 6, limitBytes: 6 * gib).effectiveJobs, 2)
        XCTAssertEqual(adviseJobs(command: "just x", env: ["CARGO_BUILD_JOBS": "4"], vmCpus: 6, limitBytes: 6 * gib).effectiveJobs, 4)
        let ok = adviseJobs(command: "cargo build -j 3", env: [:], vmCpus: 6, limitBytes: 6 * gib)
        XCTAssertFalse(ok.overBudget, "3 jobs fit within 6 GiB")
    }
}
