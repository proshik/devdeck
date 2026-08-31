import XCTest
@testable import DevDeck

/// `ClaudeTabsModel`'s two Task 2 additions: opening one session as a single explicit action, and
/// rebuilding the on-disk session catalogue off the main actor. `SessionCatalogTests` already pins
/// the pure exclusion/search functions the history section's view layer calls directly; what
/// belongs here is the wiring only `ClaudeTabsModel` can exercise — the restorer actually being
/// invoked, and a rebuild actually avoiding a re-read.
@MainActor
final class ClaudeTabsHistoryTests: XCTestCase {

    private func tempSnapshotURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude-tabs.json")
    }

    private func tempCatalogURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("agent-sessions.json")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ClaudeTabsHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    // MARK: - open(_:providerID:)

    /// The test the brief calls for by name: two fake providers with DIFFERENT ids, registered
    /// with the restorer in an order that would betray a bug — a version of `open` that ignored
    /// `providerID` and always resolved through `providers.first` would still find "claude" and
    /// pass, so "opencode" (the SECOND provider) is the one under test here.
    func testOpenInvokesTheRestorerOnceWithTheOwnProvidersCommand() async throws {
        let runner = TabRestorerTests.FakeAppleScriptRunner()
        let restorer = TabRestorer(runner: runner,
                                   providers: [FakeAgentProvider(id: "claude"), FakeAgentProvider(id: "opencode")],
                                   stepDelay: .zero)
        let model = ClaudeTabsModel(store: ClaudeTabsStore(url: tempSnapshotURL()),
                                    sessionCatalog: SessionCatalog(url: tempCatalogURL()),
                                    restorer: restorer,
                                    defaults: makeDefaults())

        model.open(AgentSession(id: "s1", title: "t", lastActivity: Date(), directory: "/tmp/a"),
                   providerID: "opencode")

        await sleepUntil({ !runner.calls.isEmpty }, message: "open() never reached the restorer")
        XCTAssertEqual(runner.calls.count, 1, "open() must invoke the restorer exactly once")
        XCTAssertTrue(runner.calls[0].joined(separator: " ").contains("opencode --resume 's1'"),
                     "the command must come from the entry's OWN provider, not whichever is first")
    }

    func testOpenBuildsTheCommandFromTheDirectoryAndSessionIDGiven() async throws {
        let runner = TabRestorerTests.FakeAppleScriptRunner()
        let restorer = TabRestorer(runner: runner, providers: [FakeAgentProvider(id: "claude")], stepDelay: .zero)
        let model = ClaudeTabsModel(store: ClaudeTabsStore(url: tempSnapshotURL()),
                                    sessionCatalog: SessionCatalog(url: tempCatalogURL()),
                                    restorer: restorer,
                                    defaults: makeDefaults())

        model.open(AgentSession(id: "s9", title: "t", lastActivity: Date(), directory: "/tmp/project"),
                   providerID: "claude")

        await sleepUntil({ !runner.calls.isEmpty }, message: "open() never reached the restorer")
        let script = runner.calls[0].joined(separator: " ")
        XCTAssertTrue(script.contains("/tmp/project"))
        XCTAssertTrue(script.contains("claude --resume 's9'"))
    }

    // MARK: - rebuildHistory()

    /// The rebuild's whole reason to exist: a second build, over a catalogue whose entries have not
    /// moved on, must not reopen the transcript it already read once. A real `LiveTranscriptIndex`
    /// wrapped in a counting reader is the same technique `TranscriptIndexTests` and Task 1's
    /// `SessionCatalogTests` use — only a real read-or-skip decision proves the merge worked, a
    /// title/list-content assertion alone would also pass a version that always rescans.
    private final class CountingFileReader: @unchecked Sendable {
        private let lock = NSLock()
        private var opened: [String: Int] = [:]
        func read(_ url: URL) -> String? {
            lock.lock(); opened[url.path, default: 0] += 1; lock.unlock()
            return try? String(contentsOf: url, encoding: .utf8)
        }
        func openCount(for url: URL) -> Int {
            lock.lock(); defer { lock.unlock() }
            return opened[url.path, default: 0]
        }
    }

    private func makeTranscriptRoot() throws -> URL {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        guard realpath(raw.path, &buffer) != nil else { return raw }
        return URL(fileURLWithPath: String(cString: buffer))
    }

    func testRebuildHistoryMergesRatherThanRescanningAnUnchangedTranscript() async throws {
        let root = try makeTranscriptRoot()
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s1.jsonl")
        // Within `SessionHistoryWindow` (7 days back from "now") — the rebuild uses the real
        // `Date()` as its window boundary, so an arbitrary past epoch would be skipped, not merged.
        let mtime = Date().addingTimeInterval(-60)
        try Data((#"{"type":"user","cwd":"/tmp/proj"}"# + "\n"
                  + #"{"type":"ai-title","aiTitle":"alpha","sessionId":"s1"}"#).utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)

        let reader = CountingFileReader()
        let model = ClaudeTabsModel(
            store: ClaudeTabsStore(url: tempSnapshotURL()),
            sessionCatalog: SessionCatalog(url: tempCatalogURL()),
            makeClaudeProvider: { known in
                ClaudeSessionProvider(index: LiveTranscriptIndex(projectsRoot: root, readFile: reader.read),
                                     backgroundSessions: FakeBackgroundSessions(ids: []),
                                     knownTranscripts: known)
            },
            makeOpencodeProvider: { _ in FakeAgentProvider(id: "opencode") },
            claudeProjectsRoot: root,
            defaults: makeDefaults())

        await model.rebuildHistory()
        XCTAssertEqual(reader.openCount(for: file), 1, "the first build must read the transcript once")
        XCTAssertEqual(model.historyEntries.map(\.title), ["alpha"])

        await model.rebuildHistory()
        XCTAssertEqual(reader.openCount(for: file), 1,
                       "a second build over an unchanged transcript must reuse the cached entry, "
                       + "not reopen the file")
        XCTAssertEqual(model.historyEntries.map(\.title), ["alpha"])
    }

    /// A file that DID change between builds must still be re-read — the other half of the same
    /// contract, so the merge is proven to be conditional and not just "never rescans anything".
    func testRebuildHistoryRereadsATranscriptThatChanged() async throws {
        let root = try makeTranscriptRoot()
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("s1.jsonl")
        func write(title: String, mtime: Date) throws {
            try Data((#"{"type":"user","cwd":"/tmp/proj"}"# + "\n"
                      + #"{"type":"ai-title","aiTitle":"\#(title)","sessionId":"s1"}"#).utf8).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: file.path)
        }
        try write(title: "first title", mtime: Date().addingTimeInterval(-120))

        let reader = CountingFileReader()
        let model = ClaudeTabsModel(
            store: ClaudeTabsStore(url: tempSnapshotURL()),
            sessionCatalog: SessionCatalog(url: tempCatalogURL()),
            makeClaudeProvider: { known in
                ClaudeSessionProvider(index: LiveTranscriptIndex(projectsRoot: root, readFile: reader.read),
                                     backgroundSessions: FakeBackgroundSessions(ids: []),
                                     knownTranscripts: known)
            },
            makeOpencodeProvider: { _ in FakeAgentProvider(id: "opencode") },
            claudeProjectsRoot: root,
            defaults: makeDefaults())

        await model.rebuildHistory()
        XCTAssertEqual(reader.openCount(for: file), 1)

        try write(title: "second title", mtime: Date().addingTimeInterval(-60))
        await model.rebuildHistory()

        XCTAssertEqual(reader.openCount(for: file), 2, "a changed transcript must be re-read")
        XCTAssertEqual(model.historyEntries.map(\.title), ["second title"])
    }

    /// `rebuildHistory()` publishes what it found, on the main actor, and persists it — the
    /// observable half of the split the brief asks for ("only the store write and the @Observable
    /// update back on the main actor").
    func testRebuildHistoryPersistsAndPublishesTheResult() async throws {
        let catalogURL = tempCatalogURL()
        let root = try makeTranscriptRoot()
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data((#"{"type":"user","cwd":"/tmp/proj"}"# + "\n"
                  + #"{"type":"ai-title","aiTitle":"alpha","sessionId":"s1"}"#).utf8)
            .write(to: project.appendingPathComponent("s1.jsonl"))
        try FileManager.default.setAttributes([.modificationDate: Date()],
                                              ofItemAtPath: project.appendingPathComponent("s1.jsonl").path)

        let model = ClaudeTabsModel(
            store: ClaudeTabsStore(url: tempSnapshotURL()),
            sessionCatalog: SessionCatalog(url: catalogURL),
            makeClaudeProvider: { known in
                ClaudeSessionProvider(index: LiveTranscriptIndex(projectsRoot: root),
                                     backgroundSessions: FakeBackgroundSessions(ids: []),
                                     knownTranscripts: known)
            },
            makeOpencodeProvider: { _ in FakeAgentProvider(id: "opencode") },
            claudeProjectsRoot: root,
            defaults: makeDefaults())

        XCTAssertTrue(model.historyEntries.isEmpty, "nothing on disk yet at construction time")
        await model.rebuildHistory()

        XCTAssertEqual(model.historyEntries.map(\.sessionID), ["s1"])
        XCTAssertEqual(SessionCatalog(url: catalogURL).load().map(\.sessionID), ["s1"],
                       "the rebuilt catalogue must have been saved to disk")
    }
}
