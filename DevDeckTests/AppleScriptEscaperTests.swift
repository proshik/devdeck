import XCTest
@testable import DevDeck

/// Escaping a string into an AppleScript `do shell script "..."` literal.
/// Pure unit test — no osascript involved.
final class AppleScriptEscaperTests: XCTestCase {

    func testPlainStringUnchanged() {
        XCTAssertEqual(AppleScriptEscaper.escape("just dev-start"), "just dev-start")
    }

    func testEscapesDoubleQuote() {
        XCTAssertEqual(AppleScriptEscaper.escape(#"echo "hi""#), #"echo \"hi\""#)
    }

    func testEscapesBackslash() {
        XCTAssertEqual(AppleScriptEscaper.escape(#"a\b"#), #"a\\b"#)
    }

    func testBackslashEscapedBeforeQuote() {
        // Input: backslash + quote  →  \\ + \"  =  \\\"
        XCTAssertEqual(AppleScriptEscaper.escape(#"\""#), #"\\\""#)
    }
}
