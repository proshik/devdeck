import XCTest
@testable import DevDeck

/// Finding the session id behind a tab title. The `ai-title` line is Claude Code's internal
/// format, so the scanner is deliberately forgiving: anything it cannot parse is skipped.
final class TranscriptIndexTests: XCTestCase {

    func testSlugReplacesSlashes() {
        XCTAssertEqual(ClaudeProjectSlug.slug(for: "/Users/me/work/app"), "-Users-me-work-app")
    }

    func testScannerTakesTheLastTitle() {
        let lines = [
            #"{"type":"user","cwd":"/tmp/a"}"#,
            #"{"type":"ai-title","aiTitle":"first","sessionId":"s1"}"#,
            #"{"type":"assistant"}"#,
            #"{"type":"ai-title","aiTitle":"second","sessionId":"s1"}"#,
        ]
        let found = TranscriptTitleScanner.lastTitle(in: lines)
        XCTAssertEqual(found?.aiTitle, "second")
        XCTAssertEqual(found?.sessionID, "s1")
    }

    func testScannerIgnoresBrokenLines() {
        let lines = [#"{"type":"ai-title","aiTitle":}"#, #"{"type":"ai-title","aiTitle":"ok","sessionId":"s2"}"#]
        XCTAssertEqual(TranscriptTitleScanner.lastTitle(in: lines)?.sessionID, "s2")
    }

    func testScannerReturnsNilWithoutTitleLines() {
        XCTAssertNil(TranscriptTitleScanner.lastTitle(in: [#"{"type":"user"}"#]))
    }

    func testLiveIndexReadsProjectDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"type":"ai-title","aiTitle":"alpha","sessionId":"s1"}"#.utf8)
            .write(to: project.appendingPathComponent("s1.jsonl"))

        let index = LiveTranscriptIndex(projectsRoot: root)
        XCTAssertEqual(index.titles(forWorkingDirectory: "/tmp/proj").map(\.sessionID), ["s1"])
    }

    func testLiveIndexFallsBackToScanningWhenTheSlugDoesNotMatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("renamed-by-some-future-claude")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data((#"{"type":"user","cwd":"/tmp/proj"}"# + "\n"
                  + #"{"type":"ai-title","aiTitle":"alpha","sessionId":"s9"}"#).utf8)
            .write(to: project.appendingPathComponent("s9.jsonl"))

        let index = LiveTranscriptIndex(projectsRoot: root)
        XCTAssertEqual(index.titles(forWorkingDirectory: "/tmp/proj").map(\.sessionID), ["s9"])
    }

    func testLiveIndexReturnsNothingForUnknownDirectory() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(LiveTranscriptIndex(projectsRoot: root).titles(forWorkingDirectory: "/nope").isEmpty)
    }
}
