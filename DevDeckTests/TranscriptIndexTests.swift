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

    /// Newest transcript first. `SessionResolver` documents in prose that two tabs with the same
    /// title are told apart by taking the first candidate — so this ordering IS the tie-break rule,
    /// and nothing else in the suite pins it.
    func testLiveIndexReturnsTheNewestTranscriptFirst() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        for (name, session, minutesAgo) in [("old.jsonl", "older", 60), ("new.jsonl", "newer", 1)] {
            let file = project.appendingPathComponent(name)
            try Data(#"{"type":"ai-title","aiTitle":"same title","sessionId":"\#(session)"}"#.utf8)
                .write(to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date().addingTimeInterval(-60 * Double(minutesAgo))],
                ofItemAtPath: file.path)
        }

        let index = LiveTranscriptIndex(projectsRoot: root)
        XCTAssertEqual(index.titles(forWorkingDirectory: "/tmp/proj").map(\.sessionID),
                       ["newer", "older"])
    }

    /// The corpus-wide fallback reads every transcript under `~/.claude/projects` — 1.1 GB on the
    /// author's machine — so a directory that has no project must be remembered as such. A tab
    /// sitting in a plain shell directory is exactly the input that reaches the fallback, and
    /// without a negative cache it would trigger that scan once a minute, forever.
    func testLiveIndexRemembersThatADirectoryHasNoProject() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = LiveTranscriptIndex(projectsRoot: root)
        XCTAssertTrue(index.titles(forWorkingDirectory: "/tmp/proj").isEmpty)

        // A project that only the expensive fallback could find, created after the miss was cached.
        let project = root.appendingPathComponent("renamed-by-some-future-claude")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data((#"{"type":"user","cwd":"/tmp/proj"}"# + "\n"
                  + #"{"type":"ai-title","aiTitle":"alpha","sessionId":"s9"}"#).utf8)
            .write(to: project.appendingPathComponent("s9.jsonl"))

        XCTAssertTrue(index.titles(forWorkingDirectory: "/tmp/proj").isEmpty,
                      "the full-corpus fallback ran a second time for the same directory")
    }

    /// The cheap half of that deal: a remembered miss is still re-checked against the slug, one
    /// `stat` per call, so a session started in a brand-new directory resolves as soon as Claude
    /// creates the project — without ever paying for the fallback again.
    func testARememberedMissStillPicksUpANewProjectDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = LiveTranscriptIndex(projectsRoot: root)
        XCTAssertTrue(index.titles(forWorkingDirectory: "/tmp/proj").isEmpty)

        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"type":"ai-title","aiTitle":"alpha","sessionId":"s1"}"#.utf8)
            .write(to: project.appendingPathComponent("s1.jsonl"))

        XCTAssertEqual(index.titles(forWorkingDirectory: "/tmp/proj").map(\.sessionID), ["s1"])
    }
}
