import XCTest
@testable import DevDeck

/// Parser for the minikube ssh probe script output:
/// `grep '^anon ' memory.stat; cat memory.max; ps -e -o rss=,comm=`.
final class MinikubeMemoryTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    func testParseValidOutputWithRustc() {
        let out = """
        anon 2193686528
        4194304000
          516888 java
          360944 kube-apiserver
         1572864 rustc
          524288 rustc
            1024 sh
        """
        let s = try! XCTUnwrap(MinikubeSample.parse(out))
        XCTAssertEqual(s.anonBytes, 2_193_686_528)
        XCTAssertEqual(s.limitBytes, 4_194_304_000)
        XCTAssertEqual(s.rustcCount, 2)
        XCTAssertEqual(s.rustcRSSBytes, (1_572_864 + 524_288) * 1024)   // ps RSS — in KiB
    }

    func testParseNoRustcGivesZeroes() {
        let out = """
        anon 1000000
        4194304000
          516888 java
        """
        let s = try! XCTUnwrap(MinikubeSample.parse(out))
        XCTAssertEqual(s.rustcCount, 0)
        XCTAssertEqual(s.rustcRSSBytes, 0)
    }

    func testParseUnlimitedMaxReturnsNil() {
        // memory.max == "max" → no limit → don't show the sample (like colima without a limit).
        XCTAssertNil(MinikubeSample.parse("anon 1000000\nmax\n  100 java"))
    }

    func testParseGarbageReturnsNil() {
        XCTAssertNil(MinikubeSample.parse(""))
        XCTAssertNil(MinikubeSample.parse("ssh: connect to host failed"))
        XCTAssertNil(MinikubeSample.parse("4194304000"))   // no anon line
    }

    func testFractionAndFormat() {
        let s = MinikubeSample(anonBytes: 2 * gib, limitBytes: 4 * gib,
                               rustcCount: 3, rustcRSSBytes: gib)
        XCTAssertEqual(s.fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.headroomFraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(s.format(), "anon 2.0 / 4.0 GiB · 50%")
    }

    func testRunStatsAbsorbKeepsIndependentMaxima() {
        let s1 = MinikubeSample(anonBytes: 3 * gib, limitBytes: 4 * gib,
                                rustcCount: 6, rustcRSSBytes: 2 * gib)
        // anon below the peak, but rustc metrics higher — the maxima are independent.
        let s2 = MinikubeSample(anonBytes: 2 * gib, limitBytes: 4 * gib,
                                rustcCount: 8, rustcRSSBytes: 3 * gib)
        var stats = MinikubeRunStats(first: s1)
        stats.absorb(s2)
        XCTAssertEqual(stats.peak.anonBytes, 3 * gib, "anon peak — from s1")
        XCTAssertEqual(stats.maxRustcCount, 8, "max rustc — from s2")
        XCTAssertEqual(stats.maxRustcRSSBytes, 3 * gib, "max rustc RSS — from s2")
    }
}
