import XCTest
import Darwin
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

    // MARK: - recentTranscripts(since:known:)

    /// Counts how many times a given file was actually opened — the seam
    /// `LiveTranscriptIndex(readFile:)` exists for. Without this, a test could only see "the right
    /// titles came back", which an implementation that re-reads everything and throws the cache
    /// away would also pass.
    private final class CountingFileReader: @unchecked Sendable {
        private let lock = NSLock()
        private var opened: [String: Int] = [:]

        func read(_ url: URL) -> String? {
            lock.lock()
            opened[url.path, default: 0] += 1
            lock.unlock()
            return try? String(contentsOf: url, encoding: .utf8)
        }

        func openCount(for url: URL) -> Int {
            lock.lock(); defer { lock.unlock() }
            return opened[url.path, default: 0]
        }
    }

    /// A fresh temp directory, canonicalized with `realpath` — `URL.resolvingSymlinksInPath()`
    /// deliberately leaves `/tmp`/`/var` alone on macOS, but `FileManager.contentsOfDirectory(at:)`
    /// still enumerates through their `/private/...` target, so a test that compares a `sourcePath`
    /// it built itself against one `LiveTranscriptIndex` reports needs both built from the same
    /// canonical root.
    private func makeTempRoot() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(raw.path, &buffer) != nil else { return raw }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    private func writeTranscript(at file: URL, sessionID: String, title: String, cwd: String,
                                 mtime: Date) throws {
        try Data((#"{"type":"user","cwd":"\#(cwd)"}"# + "\n"
                  + #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"\#(sessionID)"}"#).utf8)
            .write(to: file)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
    }

    /// The window's entire saving: a transcript older than `since` must not be opened at all, not
    /// even to find out it should be excluded.
    func testRecentTranscriptsNeverOpensAFileOlderThanTheWindow() throws {
        let root = try makeTempRoot()
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let oldFile = project.appendingPathComponent("old.jsonl")
        try writeTranscript(at: oldFile, sessionID: "old", title: "old session", cwd: "/tmp/proj",
                            mtime: Date(timeIntervalSince1970: 1000))

        let reader = CountingFileReader()
        let index = LiveTranscriptIndex(projectsRoot: root, readFile: reader.read)
        let result = index.recentTranscripts(since: Date(timeIntervalSince1970: 2000))

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(reader.openCount(for: oldFile), 0,
                       "a transcript older than the window must never be opened at all")
    }

    /// A transcript within the window is opened, and both its title and its `cwd` come out of
    /// that one read.
    func testRecentTranscriptsReadsAFileWithinTheWindow() throws {
        let root = try makeTempRoot()
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s1.jsonl")
        let mtime = Date(timeIntervalSince1970: 5000)
        try writeTranscript(at: file, sessionID: "s1", title: "alpha", cwd: "/tmp/proj", mtime: mtime)

        let reader = CountingFileReader()
        let index = LiveTranscriptIndex(projectsRoot: root, readFile: reader.read)
        let result = index.recentTranscripts(since: Date(timeIntervalSince1970: 0))

        XCTAssertEqual(result, [RecentTranscript(
            title: TranscriptTitle(aiTitle: "alpha", sessionID: "s1", modifiedAt: mtime),
            directory: "/tmp/proj", sourcePath: file.path)])
        XCTAssertEqual(reader.openCount(for: file), 1)
    }

    /// The catalog's own saving, across an app restart: a FRESH `LiveTranscriptIndex` — its own
    /// in-memory cache empty, standing in for a fresh launch — must not reopen a file whose
    /// `known` hint already carries the current mtime.
    func testRecentTranscriptsReusesAKnownHitWithoutReopening() throws {
        let root = try makeTempRoot()
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s1.jsonl")
        let mtime = Date(timeIntervalSince1970: 5000)
        try writeTranscript(at: file, sessionID: "s1", title: "alpha", cwd: "/tmp/proj", mtime: mtime)

        let reader = CountingFileReader()
        let since = Date(timeIntervalSince1970: 0)

        // "First build": nothing known yet, so the file is opened once.
        let first = LiveTranscriptIndex(projectsRoot: root, readFile: reader.read).recentTranscripts(since: since)
        XCTAssertEqual(reader.openCount(for: file), 1)

        // "Second build": a brand-new index (a fresh app launch has no in-memory cache of its own),
        // but `known` now carries what a catalog saved from the first build would have — same path,
        // same mtime.
        let known = [file.path: KnownTranscript(modifiedAt: mtime, title: first[0].title, directory: first[0].directory)]
        let second = LiveTranscriptIndex(projectsRoot: root, readFile: reader.read)
            .recentTranscripts(since: since, known: known)

        XCTAssertEqual(second, first)
        XCTAssertEqual(reader.openCount(for: file), 1,
                       "a file whose mtime matches a known hint must not be read again on a second build")
    }

    /// The other half of the same contract: a `known` hint whose mtime no longer matches the
    /// file's own must not be trusted — the file is re-read, and the fresh title wins.
    func testRecentTranscriptsRereadsAFileWhoseMtimeChangedSinceTheKnownHint() throws {
        let root = try makeTempRoot()
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s1.jsonl")
        let oldMtime = Date(timeIntervalSince1970: 1000)
        let staleKnown = [file.path: KnownTranscript(
            modifiedAt: oldMtime,
            title: TranscriptTitle(aiTitle: "stale title", sessionID: "s1", modifiedAt: oldMtime),
            directory: "/tmp/proj")]

        // The file on disk has since moved on — new content, new mtime, as a real edit would.
        let newMtime = Date(timeIntervalSince1970: 2000)
        try writeTranscript(at: file, sessionID: "s1", title: "fresh title", cwd: "/tmp/proj", mtime: newMtime)

        let reader = CountingFileReader()
        let index = LiveTranscriptIndex(projectsRoot: root, readFile: reader.read)
        let result = index.recentTranscripts(since: Date(timeIntervalSince1970: 0), known: staleKnown)

        XCTAssertEqual(result.map(\.title.aiTitle), ["fresh title"])
        XCTAssertEqual(reader.openCount(for: file), 1,
                       "a file whose mtime no longer matches its known hint must be re-read")
    }

    // MARK: - ClaudeProjectSlug.defaultProjectsRoot agreement

    /// FIX 1's whole point: `SessionCatalog.claudeCatalogEntry(for:projectsRoot:)` RECONSTRUCTS a
    /// transcript's path, and `LiveTranscriptIndex` independently REPORTS one for the same file —
    /// the on-disk catalog's match-by-(path, mtime) contract depends entirely on those two coming
    /// out equal. Both now default to the one shared `ClaudeProjectSlug.defaultProjectsRoot`
    /// instead of three separately-typed literals, but that refactor alone is not a test — this
    /// pins the actual behavior, over an injected temp root, so a future change to the slug
    /// function or either path-building call site that breaks the agreement fails here rather than
    /// only ever showing up as "the catalog got mysteriously slow again".
    func testClaudeCatalogEntrySourcePathAgreesWithWhatTheScannerReports() throws {
        let root = try makeTempRoot()
        let project = root.appendingPathComponent(ClaudeProjectSlug.slug(for: "/tmp/agreement"))
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s1.jsonl")
        try writeTranscript(at: file, sessionID: "s1", title: "alpha", cwd: "/tmp/agreement",
                            mtime: Date(timeIntervalSince1970: 5000))

        let index = LiveTranscriptIndex(projectsRoot: root)
        let reported = index.recentTranscripts(since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(reported.map(\.sourcePath), [file.path])

        let session = AgentSession(id: "s1", title: "alpha", lastActivity: Date(timeIntervalSince1970: 5000),
                                   directory: "/tmp/agreement")
        let entry = SessionCatalog.claudeCatalogEntry(for: session, projectsRoot: root)

        XCTAssertEqual(entry.sourcePath, reported.first?.sourcePath,
                       "the path SessionCatalog reconstructs must equal the path the scanner actually reported")
    }

    /// A transcript with no `cwd` line at all cannot be placed anywhere, so it is dropped rather
    /// than reported with a made-up directory.
    func testRecentTranscriptsDropsATranscriptWithNoCwd() throws {
        let root = try makeTempRoot()
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s1.jsonl")
        try Data(#"{"type":"ai-title","aiTitle":"alpha","sessionId":"s1"}"#.utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 5000)],
                                              ofItemAtPath: file.path)

        let index = LiveTranscriptIndex(projectsRoot: root)
        XCTAssertTrue(index.recentTranscripts(since: Date(timeIntervalSince1970: 0)).isEmpty)
    }
}
