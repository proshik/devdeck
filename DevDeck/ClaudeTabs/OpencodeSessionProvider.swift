import Foundation

/// Parsing of `opencode session list --format json`, lenient by the same rule as everything else
/// here: another tool's output format must cost us a missed session, never a crash.
enum OpencodeSessions {
    static func parse(_ data: Data) -> [AgentSession] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let title = entry["title"] as? String else { return nil }
            let millis = (entry["updated"] as? Double) ?? (entry["created"] as? Double) ?? 0
            return AgentSession(id: id, title: title,
                                lastActivity: Date(timeIntervalSince1970: millis / 1000))
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }
}

/// Lists opencode's sessions for a directory — behind a protocol so the provider is tested
/// without ever spawning `opencode`.
protocol OpencodeSessionListing: Sendable {
    func sessions(inDirectory directory: String) -> [AgentSession]
}

/// Real implementation over `opencode session list --format json`, cached per directory for a
/// short time.
///
/// `opencode` may not be installed at all, or the directory may not be one of its projects —
/// either way this returns an empty list silently, the same rule every external tool in this
/// feature follows for "the answer is: nothing".
///
/// Without a cache, every capture that reaches this provider spawns one `/bin/zsh -lc "opencode
/// session list …"` per opencode directory — measured at 0.44 s on this machine — and
/// `ClaudeTabsModel.captureBeforeShutdown` runs synchronously on the main actor with no timeout,
/// so an uncached call there is a real (if now rare — see `CaptureSignature`) way to make quit
/// hang. 60 s matches the base feature's original capture cadence: it is the same bound
/// `LiveTranscriptIndex`'s caches give the Claude side, and it caps how long a brand-new opencode
/// session can take to show up in a resolve at one minute.
///
/// `NSLock`, never held across the subprocess call — the same discipline `LiveTranscriptIndex` and
/// `BackgroundSessionCache` already use: take it to look or to record, drop it to do the actual
/// work.
final class LiveOpencodeSessions: OpencodeSessionListing, @unchecked Sendable {
    static let defaultTimeToLive: TimeInterval = 60

    private let timeToLive: TimeInterval
    private let now: () -> Date
    private let fetch: (String) -> [AgentSession]

    private let lock = NSLock()
    private var cache: [String: (fetchedAt: Date, sessions: [AgentSession])] = [:]

    /// `now` and `fetch` are overridable only for tests — nothing in production ever passes them,
    /// so `LiveOpencodeSessions()` alone is the real implementation, matching every other `Live*`
    /// type in this feature.
    init(timeToLive: TimeInterval = LiveOpencodeSessions.defaultTimeToLive,
         now: @escaping () -> Date = Date.init,
         fetch: @escaping (String) -> [AgentSession] = LiveOpencodeSessions.runProcess) {
        self.timeToLive = timeToLive
        self.now = now
        self.fetch = fetch
    }

    func sessions(inDirectory directory: String) -> [AgentSession] {
        lock.lock()
        if let cached = cache[directory], now().timeIntervalSince(cached.fetchedAt) < timeToLive {
            let sessions = cached.sessions
            lock.unlock()
            return sessions
        }
        lock.unlock()

        let fetched = fetch(directory)

        lock.lock()
        cache[directory] = (now(), fetched)
        lock.unlock()
        return fetched
    }

    private static func runProcess(inDirectory directory: String) -> [AgentSession] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "opencode session list --format json"]
        // The listing is scoped to the project it runs in — from an unrelated directory it
        // answers an empty array, not an error, so this must be the directory of the tab itself.
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            DiagnosticLog.shared.log("ClaudeTabs: could not list opencode sessions — "
                + error.localizedDescription)
            return []
        }
        // Drain before waiting, as everywhere else in this feature: a child that cannot write is
        // a child that never exits.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        _ = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            // The dominant case is `opencode` not being installed at all — not worth logging as
            // an error on every capture of every directory.
            return []
        }
        return OpencodeSessions.parse(data)
    }
}

/// opencode, from the restore mechanism's point of view.
///
/// Unlike Claude it stamps its own tabs with a recognizable prefix, so it never needs to be the
/// fallback and is cheap to rule out for every tab that plainly is not its own.
struct OpencodeSessionProvider: AgentSessionProvider {
    /// opencode 1.18.20 sets the Ghostty tab title to this, followed by the session's title —
    /// verified on this machine, see `docs/opencode-sessions-plan.md`.
    static let titlePrefix = "OC | "

    let id = AgentProviderID.opencode

    private let listing: OpencodeSessionListing

    init(listing: OpencodeSessionListing = LiveOpencodeSessions()) {
        self.listing = listing
    }

    func mayOwn(tabTitle: String) -> Bool {
        tabTitle.hasPrefix(Self.titlePrefix)
    }

    func sessions(inDirectory directory: String) -> [AgentSession] {
        listing.sessions(inDirectory: directory)
    }

    /// Strips the `"OC | "` prefix so the title matches the listing's `title` field exactly.
    func normalize(tabTitle: String) -> String {
        guard tabTitle.hasPrefix(Self.titlePrefix) else {
            return tabTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return String(tabTitle.dropFirst(Self.titlePrefix.count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `opencode --session <id>` — the direct analog of `claude --resume <id>`.
    func command(resuming sessionID: String, in cwd: String) -> String {
        "cd \(shellQuote(cwd)) && opencode --session \(shellQuote(sessionID))"
    }
}
