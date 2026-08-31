import Foundation

/// How far back "recent" reaches — the history list's own boundary AND, for Claude, the
/// permission to skip a transcript without opening it at all. One constant: measured at 787
/// transcripts / 1.1 GB in total against 230 / 270 MB within 7 days on the machine this was
/// designed against, so the window is what makes the difference, not a smaller number that would
/// barely trim an actively-used corpus. See `docs/agent-session-history-plan.md`.
enum SessionHistoryWindow {
    static let length: TimeInterval = 7 * 24 * 60 * 60

    static func since(_ now: Date = Date()) -> Date {
        now.addingTimeInterval(-length)
    }
}

/// A remembered session title, and what it took to learn it.
///
/// `sourcePath`/`sourceModifiedAt` exist so the next build can skip a file it has already read: a
/// transcript is opened only to learn its title, and the title changes far less often than the
/// file does not. Both are `nil` for opencode: its listing is cheap enough to trust fresh on every
/// build (see the plan's decision #4), so it has no file of its own to compare mtimes against.
struct CatalogEntry: Codable, Equatable, Sendable {
    var provider: String
    var sessionID: String
    var title: String
    var directory: String
    var lastActivity: Date
    var sourcePath: String?
    var sourceModifiedAt: Date?
}

extension CatalogEntry: Identifiable {
    /// (provider, sessionID) together — the same compound key `merge` keys entries by, so two
    /// providers reusing the same raw session id never collide as one row in the history table.
    var id: String { "\(provider)-\(sessionID)" }
}

/// Reads and writes `~/Library/Application Support/DevDeck/agent-sessions.json` — every session
/// each agent remembers within the window, built on demand (page open, refresh button) rather
/// than on a timer, per the plan's decision #3.
struct SessionCatalog: Sendable {
    let url: URL

    init(url: URL = PrivateFile.applicationSupportDirectory
            .appendingPathComponent("agent-sessions.json")) {
        self.url = url
    }

    /// Missing or malformed reads as "no entries", never throws — the catalog is disposable,
    /// rebuilt from the agents' own memory whenever it is asked for.
    func load() -> [CatalogEntry] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        return (try? decoder.decode([CatalogEntry].self, from: data)) ?? []
    }

    /// Through `PrivateFile`, like every other file DevDeck persists: 0600 in a 0700 directory —
    /// this file names every project directory the user works in, together with titles describing
    /// what they were doing in each, same reasoning `ClaudeTabsStore.save` documents.
    ///
    /// Dates are `.deferredToDate`, not `.iso8601` or `.secondsSince1970`: `sourceModifiedAt` exists
    /// to be compared for EXACT equality against a transcript's live `stat()` result (see
    /// `LiveTranscriptIndex.recentTranscripts(since:known:)`), and neither of the other two survives
    /// that round trip intact. `.iso8601` drops sub-second precision outright — a real mtime almost
    /// always carries some. `.secondsSince1970` looks safe (it is a plain `Double`) but is not: it
    /// round-trips through `date.timeIntervalSince1970`, which ADDS the ~978 million second offset
    /// to `Date`'s native `timeIntervalSinceReferenceDate` on the way out and SUBTRACTS it on the
    /// way back in, and that add-then-subtract of a large constant rounds differently often enough
    /// to change the result — measured at roughly half of the Dates tried in a 500k-sample sweep
    /// built the way a real mtime is (from `timeIntervalSinceReferenceDate`, not from a
    /// `timeIntervalSince1970` literal). Either failure mode would make a save/load round trip look
    /// like a changed file and quietly reopen every known transcript on the next rebuild.
    /// `.deferredToDate` has no such arithmetic: it serializes `timeIntervalSinceReferenceDate`
    /// directly, and the same sweep found zero mismatches.
    ///
    /// `.atomic` lands a fresh inode at the default 0644, so the mode is reapplied after the write.
    func save(_ entries: [CatalogEntry]) throws {
        try PrivateFile.makeDirectory(at: url.deletingLastPathComponent())
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(entries).write(to: url, options: .atomic)
        PrivateFile.restrict(url)
    }

    /// Entries whose source is unchanged are reused as-is; everything else is rebuilt. Pure so the
    /// "did we avoid the re-read" property is testable without touching a disk.
    ///
    /// Keyed by (provider, sessionID) — two providers are free to hand out the same raw id without
    /// one's entry reading as the other's. A cached entry wins only when BOTH `sourcePath` and
    /// `sourceModifiedAt` are present on the rescanned side AND match the cached one exactly;
    /// opencode's entries carry neither, so they always take the rescanned value, matching the
    /// "no incrementality for opencode" decision. Anything in `cached` that `rescanned` has
    /// nothing to say about — a session that fell out of the window, or one a failed rescan
    /// momentarily lost — is simply absent from the result: `rescanned` is what a full walk of the
    /// window found just now, and that is the list's whole boundary.
    static func merge(cached: [CatalogEntry], rescanned: [CatalogEntry]) -> [CatalogEntry] {
        struct Key: Hashable { var provider: String; var sessionID: String }
        var cachedByKey: [Key: CatalogEntry] = [:]
        for entry in cached {
            cachedByKey[Key(provider: entry.provider, sessionID: entry.sessionID)] = entry
        }
        return rescanned.map { entry in
            guard let sourcePath = entry.sourcePath, let sourceModifiedAt = entry.sourceModifiedAt,
                  let hit = cachedByKey[Key(provider: entry.provider, sessionID: entry.sessionID)],
                  hit.sourcePath == sourcePath, hit.sourceModifiedAt == sourceModifiedAt else {
                return entry
            }
            return hit
        }
    }
}

extension SessionCatalog {
    /// `cached`'s claude entries, reshaped into what `ClaudeSessionProvider.recentSessions(since:)`
    /// needs to skip re-reading them — the bridge between what got saved last time and what the
    /// next build hands `ClaudeSessionProvider(knownTranscripts:)`.
    ///
    /// A cached claude entry missing either `sourcePath` or `sourceModifiedAt` is dropped rather
    /// than guessed at: those two fields are written together by `claudeCatalogEntry(for:)` below,
    /// so a claude entry without them can only be a hand-edited or otherwise foreign file, and
    /// `LiveTranscriptIndex.recentTranscripts` already treats an absent hint as "read it".
    static func knownClaudeTranscripts(in cached: [CatalogEntry]) -> [String: KnownTranscript] {
        var result: [String: KnownTranscript] = [:]
        for entry in cached where entry.provider == AgentProviderID.claude {
            guard let sourcePath = entry.sourcePath, let sourceModifiedAt = entry.sourceModifiedAt else { continue }
            result[sourcePath] = KnownTranscript(
                modifiedAt: sourceModifiedAt,
                title: TranscriptTitle(aiTitle: entry.title, sessionID: entry.sessionID, modifiedAt: sourceModifiedAt),
                directory: entry.directory)
        }
        return result
    }

    /// Every directory `recentSessions(since:)` should ask opencode's directory-scoped listing
    /// about: the ones already on file for opencode in `cached`, plus whatever the caller adds —
    /// currently open tabs, so a directory is never forgotten just because its tab closed, and
    /// never missed just because nothing has been cataloged for it yet either. Sorted for a
    /// stable, testable order; deduplicated since either source may repeat the other.
    static func opencodeDirectories(in cached: [CatalogEntry], alsoInclude extra: [String] = []) -> [String] {
        let fromCatalog = cached.filter { $0.provider == AgentProviderID.opencode }.map(\.directory)
        return Array(Set(fromCatalog).union(extra)).sorted()
    }

    /// Turns one Claude `AgentSession` into a `CatalogEntry` carrying `sourcePath`/
    /// `sourceModifiedAt` — the two fields `ClaudeSessionProvider.recentSessions(since:)` itself
    /// has no reason to know about, since they describe the catalog's own bookkeeping, not the
    /// session. Reconstructed rather than threaded through `AgentSession`: Claude names a
    /// transcript `<sessionID>.jsonl` inside the project directory `ClaudeProjectSlug.slug(for:)`
    /// names, and `AgentSession.lastActivity` for Claude already IS that file's own mtime — see
    /// `ClaudeSessionProvider.sessions(inDirectory:)` / `recentSessions(since:)`.
    static func claudeCatalogEntry(for session: AgentSession,
                                   projectsRoot: URL = ClaudeProjectSlug.defaultProjectsRoot) -> CatalogEntry {
        let sourcePath = projectsRoot
            .appendingPathComponent(ClaudeProjectSlug.slug(for: session.directory))
            .appendingPathComponent("\(session.id).jsonl")
            .path
        return CatalogEntry(provider: AgentProviderID.claude, sessionID: session.id, title: session.title,
                            directory: session.directory, lastActivity: session.lastActivity,
                            sourcePath: sourcePath, sourceModifiedAt: session.lastActivity)
    }

    /// The opencode counterpart of `claudeCatalogEntry(for:)` — no source file of its own, so
    /// `sourcePath`/`sourceModifiedAt` stay `nil` and `merge` always takes the rescanned value.
    static func opencodeCatalogEntry(for session: AgentSession) -> CatalogEntry {
        CatalogEntry(provider: AgentProviderID.opencode, sessionID: session.id, title: session.title,
                    directory: session.directory, lastActivity: session.lastActivity,
                    sourcePath: nil, sourceModifiedAt: nil)
    }
}

extension SessionCatalog {
    /// What the history section of `ClaudeTabsView` actually lists: the catalogue, freshest
    /// activity first, with every entry whose session is already an open tab removed — matched on
    /// `sessionID` alone, per the plan's decision #5, since a session open right now is already
    /// visible in the table above it and repeating it below would just be noise.
    ///
    /// Pure so the exclusion is testable on its own, without a model, a snapshot, or a fake
    /// provider anywhere in sight.
    static func historyEntries(from catalog: [CatalogEntry], excludingOpenSessionIDs openSessionIDs: Set<String>) -> [CatalogEntry] {
        catalog
            .filter { !openSessionIDs.contains($0.sessionID) }
            .sorted { $0.lastActivity > $1.lastActivity }
    }

    /// The history section's search box: title OR directory, case- and diacritic-insensitive. An
    /// empty (or whitespace-only) query is "show everything" rather than "match nothing".
    static func matching(_ entries: [CatalogEntry], query: String) -> [CatalogEntry] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return entries }
        return entries.filter {
            $0.title.localizedCaseInsensitiveContains(needle) || $0.directory.localizedCaseInsensitiveContains(needle)
        }
    }
}

extension SessionCatalog {
    /// The session ids open in Ghostty **right now**, found the cheap way: by normalizing a live
    /// tab's title through its own provider and matching it against what the catalogue (built by
    /// `ClaudeTabsModel.rebuildHistory()`) already remembers — never by resolving through a
    /// transcript or a session listing, which is `SessionResolver`'s expensive path and belongs to
    /// the open-tabs snapshot alone.
    ///
    /// This is what `ClaudeTabsModel.liveOpenSessionIDs` is built from, and what the history
    /// section must exclude by instead of `snapshot?.tabs`'s session ids: the snapshot mirrors this
    /// almost always, EXCEPT in the one state the whole history feature exists for — right after a
    /// reboot and before a restore, when the snapshot lists tabs from the previous boot that the
    /// new Ghostty window has not reopened at all.
    ///
    /// A tab is handed to the first non-fallback provider whose `mayOwn` claims it, Claude tried
    /// last — the exact order `SessionResolver.resolve` uses, and for the same reason: Claude's
    /// `mayOwn` is an unconditional `true` and would otherwise swallow an opencode-prefixed title
    /// before opencode ever saw it. The tab's title is normalized through THAT provider's own
    /// `normalize(tabTitle:)` — stripping Claude's animated status glyph or opencode's `"OC | "` —
    /// and matched against a catalogue entry for the SAME provider whose own title, run through the
    /// same `normalize`, comes out identical (idempotent by the protocol's contract, so an
    /// already-bare catalogue title passes through unchanged).
    ///
    /// The match also requires the live tab's directory to name the catalogue entry's own
    /// directory — via `DirectoryMatch`, not plain string equality; see that type's doc for why.
    /// The check exists to break ties between two unrelated sessions that merely share an
    /// AI-generated title (not a rare accident — "fix the login bug" is a plausible title twice
    /// over): without it a live tab could claim the wrong catalogue entry and hide a session from
    /// history that was never actually reopened.
    ///
    /// When more than one catalogue entry still matches after that, directory SPECIFICITY is the
    /// tie-break, not recency: an `.exact` match always outranks a `.descendant` one, and recency
    /// only decides between two candidates in the same tier. Recency alone is not enough, because
    /// the descendant widening (accepting a live directory nested inside the catalogue directory,
    /// for a session started from a subdirectory) can put a genuinely unrelated PARENT-directory
    /// session in the running alongside the true CHILD-directory one whenever both happen to share
    /// a normalized title — a live tab open in the child is, by construction, a descendant of the
    /// parent's recorded directory too. Left to recency alone, an older-but-more-specific child
    /// session could lose to a newer-but-only-ancestor parent session, which both hides the parent
    /// (not actually open) from history and leaves the child's own row still offering to reopen a
    /// tab that already exists. Specificity first — exact beats descendant regardless of
    /// `lastActivity` — closes that; recency remains the tie-break `SessionResolver` itself uses
    /// once specificity no longer distinguishes two candidates.
    static func liveOpenSessionIDs(tabs: [GhosttyTab], catalog: [CatalogEntry],
                                   providers: [AgentSessionProvider]) -> Set<String> {
        let ordered = providers.filter { !$0.isFallback } + providers.filter(\.isFallback)
        var result: Set<String> = []
        for tab in tabs {
            guard let provider = ordered.first(where: { $0.mayOwn(tabTitle: tab.title) }) else { continue }
            let wanted = provider.normalize(tabTitle: tab.title)
            guard !wanted.isEmpty else { continue }
            let candidates: [(entry: CatalogEntry, kind: DirectoryMatch.Kind)] = catalog.compactMap { candidate in
                guard candidate.provider == provider.id,
                      provider.normalize(tabTitle: candidate.title) == wanted,
                      let kind = DirectoryMatch.match(liveDirectory: tab.workingDirectory,
                                                      catalogDirectory: candidate.directory)
                else { return nil }
                return (candidate, kind)
            }
            let match = candidates.max { lhs, rhs in
                lhs.kind == rhs.kind
                    ? lhs.entry.lastActivity < rhs.entry.lastActivity
                    : lhs.kind == .descendant && rhs.kind == .exact
            }
            if let match { result.insert(match.entry.sessionID) }
        }
        return result
    }
}

/// Compares a live Ghostty tab's working directory against a catalogue entry's recorded
/// directory — resiliently, because the two are read from different places and are not
/// guaranteed byte-identical for the SAME session: the catalogue's directory is the `cwd`
/// recorded inside a transcript (`TranscriptCwdScanner`), while the live one is Ghostty's own
/// `working directory of focused terminal` (`GhosttyTabReader`). A symlinked path (`/tmp` vs
/// `/private/tmp`, which this very machine exhibits) or a session started from a subdirectory of
/// the project — the same case `LiveTranscriptIndex.projectDirectory(for:)` already has a
/// slug-then-corpus-scan fallback for, see its doc comment — would otherwise make plain string
/// equality miss for the SAME session, defeating both features `SessionCatalog.liveOpenSessionIDs`
/// feeds: a miss reopens a duplicate tab, and lists the same session in both the snapshot and
/// history at once.
enum DirectoryMatch {
    /// Which of the two accepted shapes a match took — `.exact` when the live directory names the
    /// catalogue directory itself, `.descendant` when it is merely nested inside it. The two are
    /// not equally trustworthy: an `.exact` match can only be the same physical directory, while a
    /// `.descendant` match also accepts a live tab that happens to sit below a recorded directory
    /// for an entirely different, unrelated session (see `liveOpenSessionIDs`, which uses this to
    /// make specificity — not recency — the first tie-break between two candidates).
    enum Kind {
        case exact
        case descendant
    }

    /// `match(...) != nil`. Kept as a plain Bool for every call site that only needs "did this
    /// count as the same place on disk" and has no tie to break — `liveOpenSessionIDs` is the one
    /// caller that needs `match`'s richer answer instead.
    static func matches(liveDirectory: String, catalogDirectory: String) -> Bool {
        match(liveDirectory: liveDirectory, catalogDirectory: catalogDirectory) != nil
    }

    /// `.exact` when `liveDirectory` names `catalogDirectory` itself, `.descendant` when it is a
    /// directory nested inside it, `nil` otherwise. Only that one direction accepts nesting: a live
    /// directory that is merely an ANCESTOR of the catalogue directory is not accepted, since that
    /// would let an unrelated parent-directory tab (a plain shell in `~`, say) claim a session that
    /// was actually started further down. The title condition this exists alongside is the real
    /// tie-breaker; this check only widens what counts as "the same place on disk", it never
    /// substitutes for the title matching.
    static func match(liveDirectory: String, catalogDirectory: String) -> Kind? {
        let live = standardized(liveDirectory)
        let catalog = standardized(catalogDirectory)
        if live == catalog { return .exact }
        if live.hasPrefix(catalog + "/") { return .descendant }
        return nil
    }

    /// Canonicalizes via the C `realpath()`, not `URL.resolvingSymlinksInPath()`: the latter
    /// deliberately leaves `/tmp`, `/var` and `/etc` UNRESOLVED on Apple platforms (a long-standing
    /// Foundation special case for those three well-known symlinks), so it would silently fail to
    /// fix the exact miss this type exists for — verified directly: `resolvingSymlinksInPath()`
    /// left `/tmp/x` as `/tmp/x`, while `realpath()` returned `/private/tmp/x`, matching what a
    /// shell's own `cd -P` or `/bin/pwd -P` would report. Same technique
    /// `ClaudeTabsHistoryTests.makeTranscriptRoot()` already uses for the same reason.
    ///
    /// `realpath()` only succeeds when the path exists on disk end to end — both sides here always
    /// do in the case this matters for: a live tab's directory is a real shell's real cwd, and a
    /// catalogue directory that no longer exists on disk can have no live tab in it to match
    /// against anyway. A path `realpath()` cannot resolve falls back to a plain standardized form
    /// (trailing slash / "." / ".." collapsed) rather than the raw string, so the two still compare
    /// equal when they are literally the same spelling.
    private static func standardized(_ path: String) -> String {
        var buffer = [Int8](repeating: 0, count: Int(PATH_MAX))
        if realpath(path, &buffer) != nil {
            return String(cString: buffer)
        }
        return URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
