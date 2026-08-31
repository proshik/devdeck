import XCTest
@testable import DevDeck

/// `opencode session list --format json` parsing, `OpencodeSessionProvider`'s prefix/normalize/
/// command logic, and the resolver working the two agents together. No process is ever spawned —
/// `LiveOpencodeSessions` itself is exercised nowhere here, only through `OpencodeSessionListing`
/// fakes, the same probe pattern `ClaudeSessionProvider`/`TranscriptIndexing` already use.
final class OpencodeSessionProviderTests: XCTestCase {

    // MARK: - OpencodeSessions.parse

    private func json(_ raw: String) -> Data { Data(raw.utf8) }

    func testParsesAnOrdinaryListingNewestFirst() {
        let data = json("""
        [{"id":"ses_a","title":"alpha","updated":1788166882579,"created":1788166861167},
         {"id":"ses_b","title":"beta","updated":1788166872579,"created":1788166861167}]
        """)
        let sessions = OpencodeSessions.parse(data)
        XCTAssertEqual(sessions.map(\.id), ["ses_a", "ses_b"])
        XCTAssertEqual(sessions.map(\.title), ["alpha", "beta"])
        XCTAssertEqual(sessions[0].lastActivity, Date(timeIntervalSince1970: 1_788_166_882_579 / 1000))
    }

    func testFallsBackToCreatedWhenUpdatedIsMissing() {
        let data = json(#"[{"id":"ses_a","title":"alpha","created":1788166861167}]"#)
        XCTAssertEqual(OpencodeSessions.parse(data).map(\.lastActivity),
                       [Date(timeIntervalSince1970: 1_788_166_861_167 / 1000)])
    }

    func testEntryMissingBothTimestampsGetsTheEpoch() {
        let data = json(#"[{"id":"ses_a","title":"alpha"}]"#)
        XCTAssertEqual(OpencodeSessions.parse(data),
                       [AgentSession(id: "ses_a", title: "alpha", lastActivity: Date(timeIntervalSince1970: 0))])
    }

    func testMalformedOutputYieldsNothing() {
        XCTAssertEqual(OpencodeSessions.parse(json("not json at all")), [])
        XCTAssertEqual(OpencodeSessions.parse(json("{}")), [])
        XCTAssertEqual(OpencodeSessions.parse(Data()), [])
    }

    func testEmptyListingYieldsNothing() {
        XCTAssertEqual(OpencodeSessions.parse(json("[]")), [])
    }

    func testEntriesMissingIDOrTitleAreSkippedNotCrashed() {
        let data = json("""
        [{"title":"no id"},
         {"id":"ses_a"},
         {"id":"","title":"empty id is not a real id"},
         {"id":"ses_b","title":"kept"}]
        """)
        XCTAssertEqual(OpencodeSessions.parse(data).map(\.id), ["ses_b"])
    }

    // MARK: - mayOwn

    func testMayOwnRecognizesTheOpencodePrefix() {
        XCTAssertTrue(OpencodeSessionProvider().mayOwn(tabTitle: "OC | some project"))
    }

    func testMayOwnRejectsTitlesWithoutThePrefix() {
        let provider = OpencodeSessionProvider()
        XCTAssertFalse(provider.mayOwn(tabTitle: "✳ fix-own-memory"))
        XCTAssertFalse(provider.mayOwn(tabTitle: "zsh"))
        XCTAssertFalse(provider.mayOwn(tabTitle: ""))
        XCTAssertFalse(provider.mayOwn(tabTitle: "OC|no space"), "the prefix is \"OC | \", not \"OC|\"")
    }

    // MARK: - normalize

    func testNormalizeStripsThePrefix() {
        XCTAssertEqual(OpencodeSessionProvider().normalize(tabTitle: "OC | Проект: обзор и описание"),
                       "Проект: обзор и описание")
    }

    func testNormalizeTrimsWhitespaceAfterStrippingThePrefix() {
        XCTAssertEqual(OpencodeSessionProvider().normalize(tabTitle: "OC |   padded  "), "padded")
    }

    func testNormalizeOnATitleWithoutThePrefixJustTrims() {
        XCTAssertEqual(OpencodeSessionProvider().normalize(tabTitle: "  zsh  "), "zsh")
    }

    // MARK: - command(resuming:in:)

    func testCommandResumesBySessionID() {
        XCTAssertEqual(OpencodeSessionProvider().command(resuming: "ses_a", in: "/tmp/a"),
                       "cd '/tmp/a' && opencode --session 'ses_a'")
    }

    func testCommandQuotesAnAwkwardWorkingDirectoryAndSessionID() {
        XCTAssertEqual(OpencodeSessionProvider().command(resuming: "ses'a", in: "/tmp/it's here"),
                       #"cd '/tmp/it'\''s here' && opencode --session 'ses'\''a'"#)
    }

    // MARK: - id / isFallback

    func testIDIsOpencode() {
        XCTAssertEqual(OpencodeSessionProvider().id, "opencode")
        XCTAssertEqual(OpencodeSessionProvider().id, AgentProviderID.opencode)
    }

    /// opencode has its own prefix to check, so — unlike Claude — it never needs to run last.
    func testIsNotAFallback() {
        XCTAssertFalse(OpencodeSessionProvider().isFallback)
    }

    // MARK: - sessions(inDirectory:) — a thin delegation, no process spawned

    private struct FakeOpencodeSessionListing: OpencodeSessionListing {
        var byDirectory: [String: [AgentSession]] = [:]
        func sessions(inDirectory directory: String) -> [AgentSession] { byDirectory[directory] ?? [] }
    }

    func testSessionsDelegatesToTheInjectedListing() {
        let session = AgentSession(id: "ses_a", title: "alpha", lastActivity: Date())
        let provider = OpencodeSessionProvider(
            listing: FakeOpencodeSessionListing(byDirectory: ["/tmp/a": [session]]))
        XCTAssertEqual(provider.sessions(inDirectory: "/tmp/a"), [session])
        XCTAssertEqual(provider.sessions(inDirectory: "/tmp/other"), [])
    }

    // MARK: - LiveOpencodeSessions caching

    /// Counts calls per directory rather than just answering them — the whole point of these tests
    /// is to observe how OFTEN `fetch` runs, not merely that the right sessions come back.
    private final class CountingFetch: @unchecked Sendable {
        private let lock = NSLock()
        private var callCounts: [String: Int] = [:]
        var sessionsByDirectory: [String: [AgentSession]] = [:]

        func calls(for directory: String) -> Int {
            lock.lock(); defer { lock.unlock() }
            return callCounts[directory, default: 0]
        }

        func fetch(_ directory: String) -> [AgentSession] {
            lock.lock()
            callCounts[directory, default: 0] += 1
            lock.unlock()
            return sessionsByDirectory[directory] ?? []
        }
    }

    /// A mutable, thread-unsafe-but-single-threaded-here clock: each test advances it by hand
    /// instead of sleeping for real seconds.
    private final class FakeClock {
        var now = Date(timeIntervalSince1970: 0)
    }

    func testCachesWithinTheTimeToLive() {
        let fetch = CountingFetch()
        fetch.sessionsByDirectory["/tmp/a"] = [AgentSession(id: "s1", title: "one", lastActivity: Date())]
        let clock = FakeClock()
        let listing = LiveOpencodeSessions(timeToLive: 60, now: { clock.now }, fetch: fetch.fetch)

        _ = listing.sessions(inDirectory: "/tmp/a")
        clock.now.addTimeInterval(59)
        _ = listing.sessions(inDirectory: "/tmp/a")

        XCTAssertEqual(fetch.calls(for: "/tmp/a"), 1, "a call inside the TTL must reuse the cached result")
    }

    func testRefetchesOnceTheTimeToLiveHasElapsed() {
        let fetch = CountingFetch()
        let clock = FakeClock()
        let listing = LiveOpencodeSessions(timeToLive: 60, now: { clock.now }, fetch: fetch.fetch)

        _ = listing.sessions(inDirectory: "/tmp/a")
        clock.now.addTimeInterval(60)
        _ = listing.sessions(inDirectory: "/tmp/a")

        XCTAssertEqual(fetch.calls(for: "/tmp/a"), 2,
                       "a call at or past the TTL must not reuse a stale cached result")
    }

    func testEachDirectoryCachesIndependently() {
        let fetch = CountingFetch()
        let clock = FakeClock()
        let listing = LiveOpencodeSessions(timeToLive: 60, now: { clock.now }, fetch: fetch.fetch)

        _ = listing.sessions(inDirectory: "/tmp/a")
        _ = listing.sessions(inDirectory: "/tmp/b")
        _ = listing.sessions(inDirectory: "/tmp/a")
        _ = listing.sessions(inDirectory: "/tmp/b")

        XCTAssertEqual(fetch.calls(for: "/tmp/a"), 1)
        XCTAssertEqual(fetch.calls(for: "/tmp/b"), 1)
    }

    // MARK: - Resolver, end to end on a mixed tab set

    private struct FakeTranscriptIndex: TranscriptIndexing {
        var byDirectory: [String: [TranscriptTitle]] = [:]
        func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle] {
            byDirectory[workingDirectory] ?? []
        }
    }

    /// The production default order — opencode's prefix-bearing provider first, Claude the
    /// fallback last — resolves an opencode-titled tab to its opencode session and a
    /// Claude-titled tab (no prefix) to its Claude session, each keeping to its own agent.
    func testMixedTabSetResolvesEachTabToItsOwnAgent() {
        let opencode = OpencodeSessionProvider(listing: FakeOpencodeSessionListing(
            byDirectory: ["/tmp/oc": [AgentSession(id: "ses_a", title: "some project", lastActivity: Date())]]))
        let claude = ClaudeSessionProvider(
            index: FakeTranscriptIndex(byDirectory: [
                "/tmp/cc": [TranscriptTitle(aiTitle: "fix-own-memory", sessionID: "s1", modifiedAt: Date())]]),
            backgroundSessions: FakeBackgroundSessions(ids: []))

        let entries = SessionResolver.resolve(
            tabs: [
                GhosttyTab(windowID: "w1", index: 1, title: "OC | some project", workingDirectory: "/tmp/oc"),
                GhosttyTab(windowID: "w1", index: 2, title: "✳ fix-own-memory", workingDirectory: "/tmp/cc"),
            ],
            providers: [opencode, claude])

        XCTAssertEqual(entries.map(\.provider), ["opencode", "claude"])
        XCTAssertEqual(entries.map(\.sessionID), ["ses_a", "s1"])
    }

    /// A tab that looks like opencode's but has no matching session in opencode's own listing
    /// falls through to Claude, the fallback that owns every title — and, finding nothing there
    /// either, still degrades to a plain shell rather than being lost or left dangling on
    /// opencode's id.
    func testAnUnmatchedOpencodeTitleFallsThroughAndStillDegradesToAShell() {
        let opencode = OpencodeSessionProvider(listing: FakeOpencodeSessionListing())
        let claude = ClaudeSessionProvider(index: FakeTranscriptIndex(),
                                           backgroundSessions: FakeBackgroundSessions(ids: []))

        let entries = SessionResolver.resolve(
            tabs: [GhosttyTab(windowID: "w1", index: 1, title: "OC | some project", workingDirectory: "/tmp/oc")],
            providers: [opencode, claude])

        XCTAssertEqual(entries.map(\.sessionID), [nil])
        XCTAssertEqual(entries.map(\.provider), ["opencode"],
                       "opencode claimed this tab via mayOwn, so it must be named even though no session matched")
    }
}
