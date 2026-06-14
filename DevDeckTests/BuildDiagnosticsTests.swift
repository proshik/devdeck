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
}
