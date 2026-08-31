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

    /// `sourceModifiedAt` exists to be compared bit-for-bit against a transcript's live `stat()`
    /// result — see `LiveTranscriptIndex.recentTranscripts(since:known:)` — and a real file's mtime
    /// almost always carries sub-second precision. Two encodings were tried and rejected before
    /// `.deferredToDate`: `.iso8601` truncates the fractional part outright, and `.secondsSince1970`
    /// LOOKS exact but is not — it round-trips through `date.timeIntervalSince1970`, adding then
    /// subtracting the ~978-million-second 1970/2001 offset, and that arithmetic rounds differently
    /// often enough to change the result for a Date built the way a real mtime is (from
    /// `timeIntervalSinceReferenceDate`, not from a `timeIntervalSince1970` literal — measured at
    /// roughly half of a 500k-sample sweep). Building `sourceModifiedAt` via
    /// `timeIntervalSinceReferenceDate` here, not `timeIntervalSince1970`, is deliberate: a
    /// `timeIntervalSince1970` literal would round-trip through the OLD `.secondsSince1970` bug too
    /// and this test would not have caught it.
    func testRoundTripPreservesSubSecondPrecisionInSourceModifiedAt() throws {
        let url = tempURL()
        let precise = entry(sourceModifiedAt: Date(timeIntervalSinceReferenceDate: 800_000_000.123456789))
        try SessionCatalog(url: url).save([precise])
        XCTAssertEqual(SessionCatalog(url: url).load(), [precise],
                       "a fractional-second mtime must round-trip exactly, not get rounded to a nearby value")
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

    // MARK: - historyEntries (the page's own exclusion of what is already open)

    /// The property `ClaudeTabsView`'s history section exists for: a session that is currently
    /// open must not also show up below as something to reopen. Asserting the exclusion itself,
    /// not merely that SOME list comes back, is the whole point — a version that forgot to filter
    /// at all would still return a non-empty list.
    func testHistoryEntriesExcludesSessionsThatAreCurrentlyOpen() {
        let open = entry(sessionID: "open-1", title: "open one")
        let closed = entry(sessionID: "closed-1", title: "closed one")
        let result = SessionCatalog.historyEntries(from: [open, closed], excludingOpenSessionIDs: ["open-1"])
        XCTAssertEqual(result, [closed], "a session already open must not also appear in the history list")
    }

    func testHistoryEntriesKeepsEverythingWhenNothingIsOpen() {
        let a = entry(sessionID: "a")
        let b = entry(sessionID: "b")
        XCTAssertEqual(SessionCatalog.historyEntries(from: [a, b], excludingOpenSessionIDs: []), [a, b].sorted {
            $0.lastActivity > $1.lastActivity
        })
    }

    func testHistoryEntriesOrdersNewestActivityFirst() {
        let older = entry(sessionID: "older", lastActivity: Date(timeIntervalSince1970: 100))
        let newer = entry(sessionID: "newer", lastActivity: Date(timeIntervalSince1970: 200))
        // Deliberately passed in the "wrong" order, so a passthrough that skipped sorting would fail.
        XCTAssertEqual(SessionCatalog.historyEntries(from: [older, newer], excludingOpenSessionIDs: []),
                       [newer, older])
    }

    // MARK: - matching (the history section's search field)

    func testMatchingFiltersByTitle() {
        let bug = entry(sessionID: "a", title: "fix the login bug", directory: "/tmp/x")
        let docs = entry(sessionID: "b", title: "write the docs", directory: "/tmp/y")
        XCTAssertEqual(SessionCatalog.matching([bug, docs], query: "bug"), [bug])
    }

    func testMatchingFiltersByDirectory() {
        let projectX = entry(sessionID: "a", title: "alpha", directory: "/tmp/project-x")
        let projectY = entry(sessionID: "b", title: "beta", directory: "/tmp/project-y")
        XCTAssertEqual(SessionCatalog.matching([projectX, projectY], query: "project-y"), [projectY])
    }

    func testMatchingIsCaseInsensitive() {
        let entry = entry(sessionID: "a", title: "Fix The Bug", directory: "/tmp/x")
        XCTAssertEqual(SessionCatalog.matching([entry], query: "the bug"), [entry])
    }

    func testMatchingWithBlankQueryReturnsEverything() {
        let entries = [entry(sessionID: "a"), entry(sessionID: "b")]
        XCTAssertEqual(SessionCatalog.matching(entries, query: "   "), entries)
    }

    func testMatchingWithNoHitsReturnsEmpty() {
        let entries = [entry(sessionID: "a", title: "alpha", directory: "/tmp/x")]
        XCTAssertTrue(SessionCatalog.matching(entries, query: "nothing-like-this").isEmpty)
    }

    // MARK: - liveOpenSessionIDs (FIX 1 — the truthful "open right now" set)

    /// The two real providers' own `mayOwn`/`normalize` never touch disk or a subprocess — only
    /// `sessions(inDirectory:)`, `recentSessions(since:)` and `command(resuming:in:)` do, and
    /// `liveOpenSessionIDs` calls none of those — so using the real providers here (rather than
    /// `FakeAgentProvider`, whose `normalize` is a no-op) is what actually exercises Claude's
    /// status-glyph stripping and opencode's `"OC | "` stripping.
    private let realProviders: [AgentSessionProvider] = [OpencodeSessionProvider(), ClaudeSessionProvider()]

    private func tab(title: String, directory: String) -> GhosttyTab {
        GhosttyTab(windowID: "w1", index: 0, title: title, workingDirectory: directory)
    }

    func testLiveOpenSessionIDsMatchesAClaudeTabThroughItsStatusGlyph() {
        let catalog = [entry(provider: AgentProviderID.claude, sessionID: "s1", title: "foo", directory: "/tmp/a")]
        let result = SessionCatalog.liveOpenSessionIDs(
            tabs: [tab(title: "✳ foo", directory: "/tmp/a")], catalog: catalog, providers: realProviders)
        XCTAssertEqual(result, ["s1"], "the live tab's status glyph must be stripped before matching")
    }

    func testLiveOpenSessionIDsMatchesAnOpencodeTabThroughItsPrefix() {
        let catalog = [entry(provider: AgentProviderID.opencode, sessionID: "s2", title: "bar",
                             directory: "/tmp/b", sourcePath: nil, sourceModifiedAt: nil)]
        let result = SessionCatalog.liveOpenSessionIDs(
            tabs: [tab(title: "OC | bar", directory: "/tmp/b")], catalog: catalog, providers: realProviders)
        XCTAssertEqual(result, ["s2"], "the live tab's \"OC | \" prefix must be stripped before matching")
    }

    /// The directory check exists precisely to prevent this: two unrelated sessions sharing a
    /// title (a very plausible AI-generated collision) must not let a tab in one project claim a
    /// catalogue entry that actually belongs to a different one.
    func testLiveOpenSessionIDsIgnoresACatalogueEntryInADifferentDirectory() {
        let catalog = [entry(provider: AgentProviderID.claude, sessionID: "elsewhere", title: "foo",
                             directory: "/tmp/other-project")]
        let result = SessionCatalog.liveOpenSessionIDs(
            tabs: [tab(title: "foo", directory: "/tmp/a")], catalog: catalog, providers: realProviders)
        XCTAssertTrue(result.isEmpty, "a shared title in a different directory must not cross-match")
    }

    func testLiveOpenSessionIDsIgnoresACatalogueEntryFromTheWrongProvider() {
        // An opencode-titled tab must not match a Claude catalogue entry that merely normalizes
        // to the same bare text.
        let catalog = [entry(provider: AgentProviderID.claude, sessionID: "wrong-provider", title: "bar",
                             directory: "/tmp/b")]
        let result = SessionCatalog.liveOpenSessionIDs(
            tabs: [tab(title: "OC | bar", directory: "/tmp/b")], catalog: catalog, providers: realProviders)
        XCTAssertTrue(result.isEmpty)
    }

    func testLiveOpenSessionIDsReturnsEmptyWithNoTabsOrNoMatch() {
        XCTAssertTrue(SessionCatalog.liveOpenSessionIDs(tabs: [], catalog: [entry()], providers: realProviders)
            .isEmpty)
        let result = SessionCatalog.liveOpenSessionIDs(
            tabs: [tab(title: "nothing like it", directory: "/tmp/a")], catalog: [entry()], providers: realProviders)
        XCTAssertTrue(result.isEmpty)
    }

    /// When more than one catalogue entry still matches after the provider/directory/title checks
    /// — a session resumed more than once inside the same directory under the same title — the
    /// most recently active one wins, mirroring `SessionResolver`'s own tie-break rule.
    func testLiveOpenSessionIDsPicksTheMostRecentlyActiveCandidateOnATie() {
        let older = entry(sessionID: "older", title: "foo", directory: "/tmp/a",
                          lastActivity: Date(timeIntervalSince1970: 100))
        let newer = entry(sessionID: "newer", title: "foo", directory: "/tmp/a",
                          lastActivity: Date(timeIntervalSince1970: 200))
        let result = SessionCatalog.liveOpenSessionIDs(
            tabs: [tab(title: "foo", directory: "/tmp/a")], catalog: [older, newer], providers: realProviders)
        XCTAssertEqual(result, ["newer"])
    }

    /// The false positive a reviewer found in the descendant widening: two DIFFERENT sessions
    /// share a normalized title — one recorded at a parent directory with the LATER
    /// `lastActivity`, one recorded at a child directory with the EARLIER `lastActivity` — and a
    /// live tab is genuinely the child, open at the child directory. The parent's directory is
    /// only an ancestor of the live directory, never accepted by `DirectoryMatch`; the child's is
    /// an exact match. Exact specificity must beat recency here, or this returns the parent's id —
    /// which both hides the parent (not open) from history AND leaves the child's snapshot row
    /// offering to reopen a tab that already exists.
    ///
    /// Against the old `.max { $0.lastActivity < $1.lastActivity }` tie-break (recency only, both
    /// candidates already pass the directory filter) this fails: the parent's `lastActivity: 200`
    /// beats the child's `100` and `"parent"` comes back instead of `"child"`.
    func testLiveOpenSessionIDsPrefersAnExactDirectoryMatchOverAMoreRecentDescendantMatch() {
        let parent = entry(sessionID: "parent", title: "foo", directory: "/tmp/proj",
                           lastActivity: Date(timeIntervalSince1970: 200))
        let child = entry(sessionID: "child", title: "foo", directory: "/tmp/proj/sub",
                          lastActivity: Date(timeIntervalSince1970: 100))
        let result = SessionCatalog.liveOpenSessionIDs(
            tabs: [tab(title: "foo", directory: "/tmp/proj/sub")], catalog: [parent, child], providers: realProviders)
        XCTAssertEqual(result, ["child"],
                       "an exact directory match must win over a more recent descendant match")
    }

    /// Recency still decides, but only WITHIN a tier: two candidates that are both merely
    /// descendants of the live directory's ancestry (neither is an exact match) still fall back to
    /// "most recently active wins", same as two exact matches already do above.
    func testLiveOpenSessionIDsPicksTheMostRecentCandidateWithinTheDescendantTier() {
        let outer = entry(sessionID: "outer", title: "foo", directory: "/tmp/proj",
                          lastActivity: Date(timeIntervalSince1970: 100))
        let inner = entry(sessionID: "inner", title: "foo", directory: "/tmp/proj/mid",
                          lastActivity: Date(timeIntervalSince1970: 200))
        // The live tab sits below BOTH catalogue directories, so both are descendant (not exact)
        // matches — the tie-break within the tier must still be recency.
        let result = SessionCatalog.liveOpenSessionIDs(
            tabs: [tab(title: "foo", directory: "/tmp/proj/mid/leaf")], catalog: [outer, inner],
            providers: realProviders)
        XCTAssertEqual(result, ["inner"])
    }

    // MARK: - DirectoryMatch (Important review finding — resilient directory comparison)

    /// A real temp directory plus a real symlink pointing at it — `DirectoryMatch` canonicalizes
    /// via `realpath()`, which only resolves anything for a path that actually exists on disk, so
    /// a pair of string literals would not exercise it. Both are removed after the test.
    private func makeSymlinkedDirectories() throws -> (real: String, symlink: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let real = root.appendingPathComponent("real")
        let symlink = root.appendingPathComponent("link")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: real)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return (real.path, symlink.path)
    }

    /// The MISS the review named: the same session, but the live path is the symlinked form of
    /// the one the transcript recorded (`/tmp` vs `/private/tmp` on this very machine is exactly
    /// this shape). Against the old plain `==` this would miss on both sides of the pair.
    func testDirectoryMatchResolvesASymlinkedFormOfTheSamePath() throws {
        let (real, symlink) = try makeSymlinkedDirectories()
        XCTAssertTrue(DirectoryMatch.matches(liveDirectory: symlink, catalogDirectory: real),
                     "a symlinked live directory must match the real directory it points at")
        XCTAssertTrue(DirectoryMatch.matches(liveDirectory: real, catalogDirectory: symlink),
                     "and the same must hold with the symlink on the catalogue side instead")
    }

    /// The other MISS the review named: the same session, but the live tab sits in a subdirectory
    /// of the directory the transcript recorded as `cwd` — the same shape
    /// `LiveTranscriptIndex.projectDirectory(for:)` already has a fallback for.
    func testDirectoryMatchAcceptsALiveSubdirectoryOfTheCatalogueDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        XCTAssertTrue(DirectoryMatch.matches(liveDirectory: sub.path, catalogDirectory: root.path),
                     "a live directory nested inside the catalogue directory must still match")
    }

    /// Only the one direction is accepted: a live directory that is an ANCESTOR of the catalogue
    /// directory must not match — otherwise a plain shell tab sitting in `~` could claim a session
    /// that was actually started somewhere further down.
    func testDirectoryMatchRejectsACatalogueSubdirectoryOfTheLiveDirectory() {
        XCTAssertFalse(DirectoryMatch.matches(liveDirectory: "/tmp/project", catalogDirectory: "/tmp/project/sub"))
    }

    /// Guards the naive-prefix trap a careless `hasPrefix` fix would fall into: "/tmp/project" is a
    /// STRING prefix of "/tmp/project-other" without being its parent directory. This is exactly
    /// the existing protection the brief calls out — two different sessions must not cross-match
    /// merely for sharing a directory-name prefix.
    func testDirectoryMatchRejectsASiblingDirectoryWithASharedPrefix() {
        XCTAssertFalse(DirectoryMatch.matches(liveDirectory: "/tmp/project-other", catalogDirectory: "/tmp/project"))
    }

    /// Two DIFFERENT sessions sharing a title in genuinely different (non-overlapping) directories
    /// must still not cross-match — the collision protection the resilient comparison must not
    /// weaken. `testLiveOpenSessionIDsIgnoresACatalogueEntryInADifferentDirectory` above already
    /// pins this at the `liveOpenSessionIDs` level; this pins the same property directly on
    /// `DirectoryMatch` itself.
    func testDirectoryMatchRejectsGenuinelyDifferentDirectories() {
        XCTAssertFalse(DirectoryMatch.matches(liveDirectory: "/tmp/a", catalogDirectory: "/tmp/other-project"))
    }

    func testDirectoryMatchIgnoresATrailingSlashOnEitherSide() {
        XCTAssertTrue(DirectoryMatch.matches(liveDirectory: "/tmp/project/", catalogDirectory: "/tmp/project"))
        XCTAssertTrue(DirectoryMatch.matches(liveDirectory: "/tmp/project", catalogDirectory: "/tmp/project/"))
    }

    // MARK: - DirectoryMatch.match (reports WHICH kind of match, for the exact-beats-descendant tie-break)

    /// `matches` above stays a bare Bool for every existing call site's convenience; `match` is the
    /// richer form `liveOpenSessionIDs` needs to make an exact match outrank a descendant one.
    func testDirectoryMatchKindIsExactForTheSameDirectory() {
        XCTAssertEqual(DirectoryMatch.match(liveDirectory: "/tmp/project", catalogDirectory: "/tmp/project"), .exact)
    }

    func testDirectoryMatchKindIsDescendantForANestedLiveDirectory() {
        XCTAssertEqual(DirectoryMatch.match(liveDirectory: "/tmp/project/sub", catalogDirectory: "/tmp/project"),
                       .descendant)
    }

    func testDirectoryMatchKindIsNilWhenNothingMatches() {
        XCTAssertNil(DirectoryMatch.match(liveDirectory: "/tmp/a", catalogDirectory: "/tmp/other-project"))
        XCTAssertNil(DirectoryMatch.match(liveDirectory: "/tmp/project", catalogDirectory: "/tmp/project/sub"))
        XCTAssertNil(DirectoryMatch.match(liveDirectory: "/tmp/project-other", catalogDirectory: "/tmp/project"))
    }

    // MARK: - liveOpenSessionIDs — the same two MISS cases, through the whole function

    /// The MISS reproduced at the level `ClaudeTabsModel` actually calls: a live tab whose
    /// directory is the symlinked form of the one the catalogue recorded for the SAME session.
    /// Against the old `$0.directory == tab.workingDirectory`, this would miss and defeat both
    /// features that depend on `liveOpenSessionIDs` — the row action would reappear for a tab that
    /// IS open, and the session would show in the snapshot table and in history simultaneously.
    func testLiveOpenSessionIDsMatchesThroughASymlinkedWorkingDirectory() throws {
        let (real, symlink) = try makeSymlinkedDirectories()
        let catalog = [entry(provider: AgentProviderID.claude, sessionID: "s1", title: "foo", directory: real)]
        let result = SessionCatalog.liveOpenSessionIDs(
            tabs: [tab(title: "✳ foo", directory: symlink)], catalog: catalog, providers: realProviders)
        XCTAssertEqual(result, ["s1"], "a symlinked form of the recorded directory must still match")
    }

    /// The same MISS for a session started from a subdirectory of the project: the live tab's
    /// directory is a descendant of what the catalogue recorded, not an exact match.
    func testLiveOpenSessionIDsMatchesThroughALiveSubdirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sub = root.appendingPathComponent("sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }

        let catalog = [entry(provider: AgentProviderID.claude, sessionID: "s1", title: "foo", directory: root.path)]
        let result = SessionCatalog.liveOpenSessionIDs(
            tabs: [tab(title: "✳ foo", directory: sub.path)], catalog: catalog, providers: realProviders)
        XCTAssertEqual(result, ["s1"], "a live tab in a subdirectory of the recorded directory must still match")
    }
}
