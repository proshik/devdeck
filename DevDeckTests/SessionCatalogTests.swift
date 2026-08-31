import XCTest
@testable import DevDeck

/// The on-disk catalog: round-trip, malformed-reads-as-empty, and the pure `merge` that decides
/// which entries a rebuild gets to reuse without opening their source again.
final class SessionCatalogTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("agent-sessions.json")
    }

    private func entry(provider: String = AgentProviderID.claude, sessionID: String = "s1",
                       title: String = "alpha", directory: String = "/tmp/a",
                       lastActivity: Date = Date(timeIntervalSince1970: 100),
                       sourcePath: String? = "/tmp/a.jsonl",
                       sourceModifiedAt: Date? = Date(timeIntervalSince1970: 100)) -> CatalogEntry {
        CatalogEntry(provider: provider, sessionID: sessionID, title: title, directory: directory,
                    lastActivity: lastActivity, sourcePath: sourcePath, sourceModifiedAt: sourceModifiedAt)
    }

    // MARK: - load / save

    func testRoundTrip() throws {
        let url = tempURL()
        let entries = [entry(sessionID: "s1"), entry(provider: AgentProviderID.opencode, sessionID: "s2",
                             sourcePath: nil, sourceModifiedAt: nil)]
        try SessionCatalog(url: url).save(entries)
        XCTAssertEqual(SessionCatalog(url: url).load(), entries)
    }

    func testMissingFileReadsAsEmpty() {
        XCTAssertEqual(SessionCatalog(url: tempURL()).load(), [])
    }

    func testCorruptFileReadsAsEmpty() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        XCTAssertEqual(SessionCatalog(url: url).load(), [])
    }

    /// Same reasoning `ClaudeTabsStoreTests.testSaveLeavesTheSnapshotOwnerOnly` documents: this
    /// file names every project directory the user works in, with titles describing what they were
    /// doing in each.
    func testSaveLeavesTheCatalogOwnerOnly() throws {
        let url = tempURL()
        try SessionCatalog(url: url).save([entry()])

        func mode(of path: URL) throws -> Int {
            let attrs = try FileManager.default.attributesOfItem(atPath: path.path)
            return try XCTUnwrap(attrs[.posixPermissions] as? NSNumber).intValue
        }
        XCTAssertEqual(try mode(of: url), 0o600)
        XCTAssertEqual(try mode(of: url.deletingLastPathComponent()), 0o700)
    }

    // MARK: - merge

    /// The property the whole catalog exists for: an entry whose source file has not moved on is
    /// reused as-is rather than replaced by whatever the rescan produced for it. Pure — no disk,
    /// no provider, no read — so this is testable without a counting fake; the counting fake lives
    /// in `TranscriptIndexTests`, where an actual read is either paid or skipped.
    func testMergeReusesTheCachedEntryWhenTheSourceIsUnchanged() {
        let cached = entry(title: "cached title")
        let rescanned = entry(title: "rescanned title")   // same sourcePath/sourceModifiedAt
        XCTAssertEqual(SessionCatalog.merge(cached: [cached], rescanned: [rescanned]), [cached],
                       "an unchanged source must keep the cached entry, not the freshly rescanned one")
    }

    func testMergeRebuildsWhenTheSourceModifiedAtChanged() {
        let cached = entry(title: "cached title", sourceModifiedAt: Date(timeIntervalSince1970: 100))
        let rescanned = entry(title: "rescanned title", sourceModifiedAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(SessionCatalog.merge(cached: [cached], rescanned: [rescanned]), [rescanned])
    }

    func testMergeRebuildsWhenTheSourcePathChanged() {
        let cached = entry(title: "cached title", sourcePath: "/tmp/old.jsonl")
        let rescanned = entry(title: "rescanned title", sourcePath: "/tmp/new.jsonl")
        XCTAssertEqual(SessionCatalog.merge(cached: [cached], rescanned: [rescanned]), [rescanned])
    }

    /// opencode carries no `sourcePath` at all — decision #4 in the plan says its listing is cheap
    /// enough to trust fresh every time, so it always takes the rescanned value even when nothing
    /// about the session actually changed.
    func testMergeAlwaysTakesTheRescannedValueWhenThereIsNoSourcePath() {
        let cached = entry(provider: AgentProviderID.opencode, title: "cached title",
                           sourcePath: nil, sourceModifiedAt: nil)
        let rescanned = entry(provider: AgentProviderID.opencode, title: "rescanned title",
                              sourcePath: nil, sourceModifiedAt: nil)
        XCTAssertEqual(SessionCatalog.merge(cached: [cached], rescanned: [rescanned]), [rescanned])
    }

    /// A session with no cached counterpart at all — brand new this build — is simply included.
    func testMergeKeepsARescannedEntryWithNoCachedCounterpart() {
        let rescanned = entry(sessionID: "new")
        XCTAssertEqual(SessionCatalog.merge(cached: [], rescanned: [rescanned]), [rescanned])
    }

    /// A cached entry the rescan no longer reports — it fell out of the window, or its provider
    /// briefly failed to list it — is not carried forward: `rescanned` is a full walk of the
    /// window, and that walk is the list's own boundary.
    func testMergeDropsACachedEntryTheRescanNoLongerReports() {
        let cached = entry(sessionID: "gone")
        XCTAssertEqual(SessionCatalog.merge(cached: [cached], rescanned: []), [])
    }

    /// Two providers are free to reuse the same raw session id — the key is (provider, sessionID),
    /// not sessionID alone.
    func testMergeKeysByProviderAndSessionIDTogether() {
        let cachedClaude = entry(provider: AgentProviderID.claude, sessionID: "shared", title: "claude cached",
                                 sourcePath: "/tmp/a.jsonl", sourceModifiedAt: Date(timeIntervalSince1970: 1))
        let rescannedOpencode = entry(provider: AgentProviderID.opencode, sessionID: "shared",
                                      title: "opencode rescanned", sourcePath: nil, sourceModifiedAt: nil)
        XCTAssertEqual(SessionCatalog.merge(cached: [cachedClaude], rescanned: [rescannedOpencode]),
                       [rescannedOpencode])
    }

    // MARK: - knownClaudeTranscripts

    func testKnownClaudeTranscriptsBridgesCachedEntriesForTheProvider() {
        let cached = [
            entry(sessionID: "s1", title: "alpha", directory: "/tmp/a", sourcePath: "/tmp/a.jsonl",
                 sourceModifiedAt: Date(timeIntervalSince1970: 10)),
            entry(provider: AgentProviderID.opencode, sessionID: "s2", sourcePath: nil, sourceModifiedAt: nil),
        ]
        let known = SessionCatalog.knownClaudeTranscripts(in: cached)
        XCTAssertEqual(known, ["/tmp/a.jsonl": KnownTranscript(
            modifiedAt: Date(timeIntervalSince1970: 10),
            title: TranscriptTitle(aiTitle: "alpha", sessionID: "s1", modifiedAt: Date(timeIntervalSince1970: 10)),
            directory: "/tmp/a")])
    }

    func testKnownClaudeTranscriptsDropsAnEntryMissingEitherSourceField() {
        let cached = [entry(sourcePath: nil), entry(sessionID: "s2", sourceModifiedAt: nil)]
        XCTAssertTrue(SessionCatalog.knownClaudeTranscripts(in: cached).isEmpty)
    }

    // MARK: - opencodeDirectories

    func testOpencodeDirectoriesUnionsCatalogAndOpenTabs() {
        let cached = [
            entry(provider: AgentProviderID.opencode, directory: "/tmp/from-catalog",
                 sourcePath: nil, sourceModifiedAt: nil),
            entry(directory: "/tmp/claude-only"),   // a claude entry must not leak in here
        ]
        XCTAssertEqual(SessionCatalog.opencodeDirectories(in: cached, alsoInclude: ["/tmp/open-tab"]),
                       ["/tmp/from-catalog", "/tmp/open-tab"])
    }

    func testOpencodeDirectoriesDeduplicates() {
        let cached = [entry(provider: AgentProviderID.opencode, directory: "/tmp/a",
                            sourcePath: nil, sourceModifiedAt: nil)]
        XCTAssertEqual(SessionCatalog.opencodeDirectories(in: cached, alsoInclude: ["/tmp/a"]), ["/tmp/a"])
    }

    // MARK: - claudeCatalogEntry / opencodeCatalogEntry

    func testClaudeCatalogEntryReconstructsTheTranscriptPath() {
        let session = AgentSession(id: "s1", title: "alpha", lastActivity: Date(timeIntervalSince1970: 42),
                                   directory: "/tmp/a")
        let root = URL(fileURLWithPath: "/fake/root")
        let result = SessionCatalog.claudeCatalogEntry(for: session, projectsRoot: root)
        XCTAssertEqual(result, CatalogEntry(provider: AgentProviderID.claude, sessionID: "s1", title: "alpha",
                                            directory: "/tmp/a", lastActivity: Date(timeIntervalSince1970: 42),
                                            sourcePath: "/fake/root/-tmp-a/s1.jsonl",
                                            sourceModifiedAt: Date(timeIntervalSince1970: 42)))
    }

    func testOpencodeCatalogEntryHasNoSourcePath() {
        let session = AgentSession(id: "ses_a", title: "alpha", lastActivity: Date(timeIntervalSince1970: 42),
                                   directory: "/tmp/oc")
        let result = SessionCatalog.opencodeCatalogEntry(for: session)
        XCTAssertNil(result.sourcePath)
        XCTAssertNil(result.sourceModifiedAt)
        XCTAssertEqual(result.provider, AgentProviderID.opencode)
        XCTAssertEqual(result.directory, "/tmp/oc")
    }

    // MARK: - SessionHistoryWindow

    func testSessionHistoryWindowIsSevenDaysBack() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(SessionHistoryWindow.since(now), now.addingTimeInterval(-7 * 24 * 60 * 60))
    }
}
