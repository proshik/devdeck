import XCTest
@testable import DevDeck

/// Parsing the tab-separated dump our AppleScript prints. The title is user-controlled and may
/// contain tabs itself, so the parser must not simply split into four fields.
final class GhosttyTabParserTests: XCTestCase {

    func testParsesOneTab() {
        let out = "tab-group-1\t1\t✳ work on grount\t/Users/me/work/grount\n"
        XCTAssertEqual(GhosttyTabParser.parse(out),
                       [GhosttyTab(windowID: "tab-group-1", index: 1,
                                   title: "✳ work on grount",
                                   workingDirectory: "/Users/me/work/grount")])
    }

    func testTitleMayContainTabs() {
        let out = "w1\t2\ttitle\twith\ttabs\t/tmp/x\n"
        XCTAssertEqual(GhosttyTabParser.parse(out).first?.title, "title\twith\ttabs")
        XCTAssertEqual(GhosttyTabParser.parse(out).first?.workingDirectory, "/tmp/x")
    }

    func testSkipsMalformedAndEmptyLines() {
        let out = "w1\t1\tok\t/tmp/a\n\ngarbage\nw1\tnotanumber\tbad\t/tmp/b\n"
        XCTAssertEqual(GhosttyTabParser.parse(out).map(\.workingDirectory), ["/tmp/a"])
    }

    func testParsesSeveralWindows() {
        let out = "w1\t1\ta\t/tmp/a\nw2\t1\tb\t/tmp/b\n"
        XCTAssertEqual(GhosttyTabParser.parse(out).map(\.windowID), ["w1", "w2"])
    }

    /// The generated AppleScript must separate fields with an explicit tab CHARACTER.
    ///
    /// Inside `tell application "Ghostty"` the term `tab` is Ghostty's own `tab` class, not
    /// AppleScript's text constant, so `& tab &` emits the word "tab" and every line arrives with
    /// no separators — the parser then drops all of them and the feature silently sees zero tabs.
    /// This shipped, and no test caught it: the parser is tested on synthetic strings and the
    /// script is deliberately never executed in tests, so only the seam between them was exposed.
    func testScriptSeparatesFieldsWithARealTabNotTheShadowedTerm() {
        let script = LiveGhosttyTabReader.scriptArgs.joined(separator: "\n")
        XCTAssertTrue(script.contains("ASCII character 9"),
                      "the separator must be an explicit tab character")
        XCTAssertFalse(script.contains("& tab &"),
                       "`tab` inside the tell block is Ghostty's class, not a tab character")
    }

    func testEmptyOutputGivesNoTabs() {
        XCTAssertTrue(GhosttyTabParser.parse("").isEmpty)
    }
}
