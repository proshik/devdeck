import XCTest
@testable import DevDeck

/// Naming of duplicated entries. Pure — no store, no files, no app language state,
/// so both locales are covered by passing the marker in.
final class DuplicateNamingTests: XCTestCase {

    private let markers = ["copy", "копия"]

    private func next(_ base: String, existing: Set<String>, marker: String = "copy") -> String {
        DuplicateNaming.nextName(base: base, marker: marker,
                                 knownMarkers: markers, existing: existing)
    }

    func testFirstCopyAppendsTheMarker() {
        XCTAssertEqual(next("deploy", existing: ["deploy"]), "deploy (copy)")
    }

    func testCollisionAdvancesToTwo() {
        XCTAssertEqual(next("deploy", existing: ["deploy", "deploy (copy)"]), "deploy (copy 2)")
    }

    func testDuplicatingACopyReusesTheRoot() {
        XCTAssertEqual(next("deploy (copy)", existing: ["deploy", "deploy (copy)"]),
                       "deploy (copy 2)",
                       "no 'deploy (copy) (copy)'")
    }

    func testNumberedCopyIsStrippedToo() {
        XCTAssertEqual(next("deploy (copy 2)",
                            existing: ["deploy", "deploy (copy)", "deploy (copy 2)"]),
                       "deploy (copy 3)")
    }

    func testGapInTheNumberingIsFilled() {
        XCTAssertEqual(next("deploy", existing: ["deploy", "deploy (copy)", "deploy (copy 3)"]),
                       "deploy (copy 2)",
                       "lowest free candidate, not highest used + 1")
    }

    func testEmptyNameGetsNoLeadingSpace() {
        XCTAssertEqual(next("", existing: []), "(copy)")
        XCTAssertEqual(next("", existing: ["(copy)"]), "(copy 2)")
    }

    func testMarkerFromTheOtherLanguageIsRecognized() {
        // A copy made in Russian, duplicated after the user switched to English.
        XCTAssertEqual(next("deploy (копия)", existing: ["deploy", "deploy (копия)"]),
                       "deploy (copy)")
    }

    func testRussianMarkerIsWrittenWhenAsked() {
        XCTAssertEqual(next("deploy", existing: ["deploy"], marker: "копия"), "deploy (копия)")
    }

    func testAMarkerInTheMiddleIsNotStripped() {
        XCTAssertEqual(next("deploy (copy) of prod", existing: []),
                       "deploy (copy) of prod (copy)",
                       "only a trailing marker is a copy suffix")
    }
}
