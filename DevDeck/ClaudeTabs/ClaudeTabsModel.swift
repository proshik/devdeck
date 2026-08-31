import AppKit

enum SnapshotPolicy {
    /// A snapshot is worth writing only when at least one tab resolved to a session.
    ///
    /// This is the spec's rule ("Снятие снимка"), and not the tautology it replaces: the capture
    /// path already returns early on an empty tab list and the resolver maps 1:1, so "the entries
    /// are not empty" was always true. What the real rule stops is the two ways the feature could
    /// erase itself — a Ghostty that is quitting (no tabs at all), and the moment just after a
    /// restore, when the new tabs still show the shell's title and nothing resolves yet. Both
    /// would replace a good snapshot with one that restores nothing.
    static func shouldPersist(_ entries: [ClaudeTabEntry]) -> Bool {
        entries.contains { $0.sessionID != nil }
    }
}

/// What one capture found. Computed off the main actor, applied on it — hence `Sendable`.
enum CaptureOutcome: Equatable, Sendable {
    case notRunning
    case failed(String)
    case entries([ClaudeTabEntry], signature: [GhosttyTab])
    /// The open tab set matches the previous capture's signature exactly — nothing to resolve, and
    /// nothing to apply.
    case unchanged
}

/// The capture interval, kept inside sane bounds.
///
/// `config.json` is hand-edited and both ends are real hazards: 0 would spin the timer, and a
/// day would leave the feature silently off. Clamping beats rejecting — a nonsense value should
/// still leave a working app.
enum ClaudeTabsCaptureInterval {
    static let minimum = 5
    static let maximum = 300
    static let fallback = 15

    static func clamped(_ seconds: Int) -> TimeInterval {
        TimeInterval(min(max(seconds, minimum), maximum))
    }
}

/// Ghostty, as an application on this Mac.
enum GhosttyApp {
    static let bundleID = "com.mitchellh.ghostty"

    /// Asks the workspace, not Ghostty: no Apple event, so no Automation prompt.
    static func isRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == bundleID }
    }
}

/// Owns the capture timer, the Ghostty-launch observer and the restore flow.
///
/// Everything it decides lives in `SessionResolver`, `RestorePlanner` and `SnapshotPolicy`;
/// this type is deliberately only wiring, so the untestable parts stay thin.
@MainActor
@Observable
final class ClaudeTabsModel {

    /// UserDefaults, not the config: this is execution state, and it must not travel with a
    /// hand-edited config.json.
    private static let restoredBootTimeKey = "claudeTabs.restoredBootTime"

    /// A snapshot younger than this is current enough for a shutdown; see `captureBeforeShutdown`.
    private static let shutdownFreshness: TimeInterval = 30

    private(set) var snapshot: ClaudeTabsSnapshot?
    private(set) var lastError: String?

    private let reader: GhosttyTabReading
    private let index: TranscriptIndexing
    private let store: ClaudeTabsStore
    private let bootTime: BootTimeProviding
    private let restorer: TabRestorer
    private let defaults: UserDefaults
    private let isGhosttyRunning: () -> Bool
    private var isEnabled: () -> Bool
    private var captureInterval: () -> TimeInterval = {
        ClaudeTabsCaptureInterval.clamped(ClaudeTabsCaptureInterval.fallback)
    }
    private var timer: Timer?
    /// Set for the duration of a restore — including the delay it waits out before touching
    /// Ghostty — so the automatic capture cannot capture a half-restored tab set and overwrite
    /// the snapshot with it. Also what keeps a second trigger (the launch observer firing twice, a
    /// "Restore now" press mid-restore) from racing the first (see `runRestore`).
    private var isRestoring = false
    /// So the "refusing to capture" line is logged once per state change, not on every tick.
    private var loggedCaptureHold = false
    /// The signature of the last APPLIED capture — `nil` means "treat the next tick as a fresh
    /// capture", which is also why it is reset on `.failed` and `.notRunning`: a read that didn't
    /// produce a tab set must not be mistaken for an unchanged one.
    ///
    /// The signature IS the tab set: comparing `[GhosttyTab]` directly (rather than joining fields
    /// into a string) is what keeps a tab character embedded in a title from shifting field
    /// boundaries and making two different tab sets compare equal.
    private var lastSignature: [GhosttyTab]?
    /// Throttles the automatic timer path only; `captureNow()` is an explicit user action and
    /// `captureBeforeShutdown()` has its own 30-second freshness rule — neither goes through `tick`.
    private var lastCaptureAt: Date?
    /// `isEnabled()` as of the last tick — lets `tick()` notice a false→true transition (the
    /// toggle switched on mid-boot) and run a restore for it exactly once, rather than on every
    /// tick thereafter. Seeded from the real value in `start()`.
    private var wasEnabled = false

    init(reader: GhosttyTabReading = LiveGhosttyTabReader(),
         index: TranscriptIndexing = LiveTranscriptIndex(),
         store: ClaudeTabsStore = ClaudeTabsStore(),
         bootTime: BootTimeProviding = LiveBootTime(),
         restorer: TabRestorer = TabRestorer(),
         defaults: UserDefaults = .standard,
         isEnabled: @escaping () -> Bool = { false },
         isGhosttyRunning: @escaping () -> Bool = GhosttyApp.isRunning) {
        self.reader = reader
        self.index = index
        self.store = store
        self.bootTime = bootTime
        self.restorer = restorer
        self.defaults = defaults
        self.isEnabled = isEnabled
        self.isGhosttyRunning = isGhosttyRunning
        self.snapshot = store.load()
    }

    func start(isEnabled: @escaping () -> Bool,
               captureInterval: @escaping () -> TimeInterval) {
        self.isEnabled = isEnabled
        self.captureInterval = captureInterval
        // Seeded now, not left at its `false` default: a feature already on at launch must not
        // read as a false→true transition on the very first tick.
        wasEnabled = isEnabled()

        // A short fixed tick that mostly does nothing, rather than a timer scheduled at the
        // configured interval: it lets a hand-edited config.json take effect immediately, and a
        // date comparison every 5s costs nothing next to what it guards.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == GhosttyApp.bundleID else { return }
            Task { @MainActor in await self?.runRestore(startupDelay: .milliseconds(1500)) }
        }
        center.addObserver(forName: NSWorkspace.willPowerOffNotification,
                           object: nil, queue: .main) { [weak self] _ in
            // Synchronously, on the notification's own main-queue delivery: the session is being
            // torn down and a Task scheduled here may simply never be run. `captureBeforeShutdown`
            // is the bounded path that exists for this.
            MainActor.assumeIsolated { self?.captureBeforeShutdown() }
        }

        restoreIfGhosttyAlreadyRunning()
    }

    /// Ghostty may already be up when DevDeck reaches this point — the app is a login item, and a
    /// user who reboots and opens Ghostty by hand beats it to the desktop easily. Without this the
    /// launch notification never arrives, no restore is ever attempted, and the first capture of
    /// this boot overwrites the very snapshot the reboot was supposed to bring back.
    ///
    /// An unconditional attempt is safe: `isRestoring` stops it from overlapping anything, and the
    /// planner's `restoredBootTime` guard stops it from restoring twice in one boot.
    func restoreIfGhosttyAlreadyRunning() {
        guard isGhosttyRunning() else { return }
        DiagnosticLog.shared.log("ClaudeTabs: Ghostty was already running at launch — checking for a restore")
        Task { @MainActor in await runRestore() }
    }

    // MARK: - Capture

    /// Explicit user-initiated capture (the "Capture now" button) — deliberately bypasses the
    /// feature flag, mirroring how `restoreNow()` forces the restore, and unlike the automatic path
    /// it reports every outcome: a button that does nothing and says nothing is a bug report.
    ///
    /// That is also why it passes `previousSignature: nil` rather than `lastSignature`: the
    /// signature short-circuit exists to make an unattended tick free when nothing changed, but a
    /// press is never unattended. Skipping the transcript pass here would make the button go quiet
    /// on an unchanged tab set — indistinguishable, to the user, from a broken feature, and most
    /// likely to look broken precisely when everything is fine. `nil` guarantees a real capture,
    /// exactly as `force` bypasses the restore planner's guards on the restore side.
    ///
    /// It does not bypass `isRestoring`. Pressing it during a restore — including the second and a
    /// half where Ghostty has opened its first tab and nothing has been restored into it yet —
    /// would snapshot a tab set that is not the user's, and the user has no way of seeing that a
    /// restore is under way. Refusing and saying so is the only honest answer.
    func captureNow() {
        guard !isRestoring else {
            lastError = L10n.claudeTabsRestoreInProgress
            return
        }
        Task { @MainActor in await capture(explicit: true, previousSignature: nil) }
    }

    /// The automatic path — gated by the configured interval. Respects the feature flag, is
    /// suppressed while a restore is in flight, and never overwrites a snapshot that is still owed
    /// a restore. This is the path whose whole purpose is to cost nothing when nothing changed, so
    /// it is the one that passes `lastSignature` through.
    func captureIfEnabled() async {
        guard isEnabled(), !isRestoring, mayOverwriteSnapshot() else { return }
        await capture(explicit: false, previousSignature: lastSignature)
    }

    /// Runs every 5 seconds; does real work only once `captureInterval()` has actually elapsed.
    /// Reading the interval here rather than baking it into the timer's own schedule is what lets a
    /// hand-edited `config.json` take effect immediately.
    ///
    /// Not `private`: tests drive it directly rather than waiting on a real 5-second `Timer`.
    ///
    /// Also where a false→true transition of `isEnabled()` is noticed. `restoreIfGhosttyAlreadyRunning`
    /// only ever runs once from `start()` and once per Ghostty launch notification — neither fires
    /// when the toggle is switched on later in the same boot with Ghostty already up, so nothing
    /// would ever restore until Ghostty relaunches. Checking on the transition, not on every tick,
    /// keeps this a single log line rather than noise; `isRestoring` and `restoredBootTime` already
    /// make a stray extra call harmless.
    func tick() async {
        let enabledNow = isEnabled()
        if enabledNow, !wasEnabled {
            DiagnosticLog.shared.log("ClaudeTabs: restore turned on mid-boot — checking for a restore")
            restoreIfGhosttyAlreadyRunning()
        }
        wasEnabled = enabledNow

        let elapsed = Date().timeIntervalSince(lastCaptureAt ?? .distantPast)
        guard elapsed >= captureInterval() else { return }
        lastCaptureAt = Date()
        await captureIfEnabled()
    }

    /// The last capture before the machine — or the app — goes away: `willPowerOffNotification`
    /// and `applicationWillTerminate`. Neither can await, so this path is synchronous, and made
    /// safe by being **bounded** rather than by being asynchronous:
    ///
    /// - the transcript work is bounded by `LiveTranscriptIndex`'s two caches (titles per (file,
    ///   mtime), project directories per working directory including misses), so the full-corpus
    ///   fallback cannot run here more than once per directory per app run;
    /// - a snapshot taken in the last 30 seconds is current enough for a shutdown, and this path
    ///   then does no work at all. The tab set does not change in the half minute before a
    ///   shutdown; the risk of being killed mid-read does.
    ///
    /// The remaining cost is a `pgrep`, one `osascript` enumeration and re-reading the transcripts
    /// whose mtime moved since the last capture — hundreds of milliseconds, spent inside the
    /// window macOS gives, and spent only when the snapshot on disk is genuinely stale.
    func captureBeforeShutdown() {
        guard isEnabled(), !isRestoring, mayOverwriteSnapshot() else { return }
        if let capturedAt = snapshot?.capturedAt,
           Date().timeIntervalSince(capturedAt) < Self.shutdownFreshness {
            DiagnosticLog.shared.log("ClaudeTabs: shutting down — the snapshot is under "
                + "\(Int(Self.shutdownFreshness)) s old, keeping it as it is")
            return
        }
        apply(Self.collect(reader: reader, index: index, previousSignature: lastSignature), explicit: false)
    }

    /// THE INVARIANT: a snapshot from a previous boot is the only copy of the user's tabs and must
    /// not be overwritten until this boot's restore has been resolved.
    ///
    /// Everything else in this feature is recoverable; this is not. The snapshot is written with
    /// `bootTime == currentBoot`, and from that moment every future launch reads "same boot" and
    /// skips — the tabs are gone, with no message and no undo. So the automatic capture runs only
    /// when there is nothing to lose (no snapshot at all), when the snapshot already belongs to
    /// this boot, or when this boot's restore is done (`restoredBootTime == currentBootTime`).
    ///
    /// A snapshot left un-restored — the feature was switched on mid-boot, or Automation is still
    /// denied — therefore blocks captures until a restore resolves it. That is the intended
    /// trade-off: an older snapshot restored late beats a fresh snapshot that erased the old one.
    private func mayOverwriteSnapshot() -> Bool {
        let mayOverwrite = Self.mayOverwrite(stored: store.load(), currentBoot: bootTime.bootTime(),
                                             restoredBootTime: defaults.object(forKey: Self.restoredBootTimeKey) as? Date)
        if mayOverwrite {
            loggedCaptureHold = false
        } else if !loggedCaptureHold {
            loggedCaptureHold = true
            DiagnosticLog.shared.log("ClaudeTabs: holding the snapshot — it is from an earlier boot "
                + "and has not been restored yet")
        }
        return mayOverwrite
    }

    /// Read-only mirror of the invariant above, for the UI: true while a stored snapshot is from
    /// an earlier, not-yet-restored boot and so is the last copy of the user's tabs — the case
    /// "Capture now" must confirm before overwriting. Built on the SAME condition
    /// `mayOverwriteSnapshot()` uses, so the gate and the warning can never drift apart.
    var isHoldingEarlierBootSnapshot: Bool {
        !Self.mayOverwrite(stored: store.load(), currentBoot: bootTime.bootTime(),
                           restoredBootTime: defaults.object(forKey: Self.restoredBootTimeKey) as? Date)
    }

    private static func mayOverwrite(stored: ClaudeTabsSnapshot?, currentBoot: Date,
                                     restoredBootTime: Date?) -> Bool {
        guard let stored else { return true }
        return BootInstant.same(stored.bootTime, currentBoot)
            || BootInstant.same(currentBoot, restoredBootTime)
    }

    /// Reads Ghostty and resolves the sessions **off the main actor**, then applies the result on
    /// it. The work behind `collect` forks `pgrep` and `osascript` and reads whole transcripts —
    /// on this machine 1.1 GB of them, with the active session's file changing mtime constantly —
    /// which is not something a menu-bar app may do to its own UI thread on every capture. Same
    /// treatment as `ProcessManager.refreshVMDisk` gives its blocking probes.
    ///
    /// `previousSignature` is threaded in by the caller rather than read from `lastSignature`
    /// here, so each caller can decide for itself whether the signature short-circuit applies —
    /// see `captureNow()` and `captureIfEnabled()`.
    private func capture(explicit: Bool, previousSignature: [GhosttyTab]?) async {
        let reader = self.reader
        let index = self.index
        let outcome = await Task.detached(priority: .utility) {
            Self.collect(reader: reader, index: index, previousSignature: previousSignature)
        }.value
        apply(outcome, explicit: explicit)
    }

    /// Read + resolve, with nothing actor-bound in it, so the async path and the synchronous
    /// shutdown path run exactly the same code.
    ///
    /// `previousSignature` is the tab set of the last APPLIED capture; a `.tabs` read that matches
    /// it exactly (`GhosttyTab` is `Equatable`) skips the transcript pass entirely — that pass is
    /// the expensive part (whole transcripts re-read on every mtime change), while enumerating the
    /// tabs themselves is one cheap AppleScript round trip. Comparing the tabs directly, rather
    /// than a string joined from their fields, is deliberate: a title containing a tab character
    /// could otherwise shift field boundaries and make two different tab sets compare equal.
    nonisolated static func collect(reader: GhosttyTabReading,
                                    index: TranscriptIndexing,
                                    previousSignature: [GhosttyTab]?) -> CaptureOutcome {
        switch reader.readTabs() {
        case .notRunning:
            return .notRunning
        case let .failed(message):
            return .failed(message)
        case let .tabs(tabs):
            guard tabs != previousSignature else { return .unchanged }
            let providers: [AgentSessionProvider] = [ClaudeSessionProvider(index: index)]
            return .entries(SessionResolver.resolve(tabs: tabs, providers: providers), signature: tabs)
        }
    }

    /// The main-actor half: the store write and the observable properties, nothing else.
    private func apply(_ outcome: CaptureOutcome, explicit: Bool) {
        switch outcome {
        case .notRunning:
            // Silent on the automatic path — a Mac with no terminal open is not an error. Reported
            // when the user pressed the button, because then it is the answer to their question.
            if explicit { lastError = L10n.claudeTabsGhosttyNotRunning }
            // A read that produced no tab set at all must not be mistaken for "unchanged" — the
            // next tick has to do real work.
            lastSignature = nil
        case let .failed(message):
            // Always surfaced: this is Automation being denied, and it is invisible everywhere else.
            lastError = L10n.claudeTabsCaptureFailed(message)
            lastSignature = nil
        case .unchanged:
            // Nothing resolved, nothing to persist, nothing observable changes — this is the whole
            // point: the transcript pass already didn't run, and `apply` doesn't touch the store or
            // any @Observable property either.
            break
        case let .entries(entries, signature):
            guard SnapshotPolicy.shouldPersist(entries) else {
                DiagnosticLog.shared.log("ClaudeTabs: not writing a snapshot — no open tab resolved "
                    + "to a session, the previous snapshot stands")
                if explicit { lastError = L10n.claudeTabsNothingResolved }
                return
            }
            let fresh = ClaudeTabsSnapshot(bootTime: bootTime.bootTime(), capturedAt: Date(), tabs: entries)
            do {
                try store.save(fresh)
                snapshot = fresh
                lastError = nil
                lastSignature = signature
            } catch {
                lastError = error.localizedDescription
                DiagnosticLog.shared.log("ClaudeTabs: snapshot write failed — \(error.localizedDescription)",
                                         level: .error)
            }
        }
    }

    // MARK: - Restore

    func restoreNow() { Task { @MainActor in await runRestore(force: true) } }

    /// `startupDelay` is the pause Ghostty needs to put up its first window after launching. It is
    /// waited out *inside* the `isRestoring` guard on purpose: a capture landing in that window
    /// would snapshot the one fresh tab Ghostty just opened and call it the user's session list.
    private func runRestore(force: Bool = false, startupDelay: Duration = .zero) async {
        // A restore already in flight owns `isRestoring`; a second trigger (the launch observer
        // firing again, or a "Restore now" button press) must not race its actions or its
        // `defer`-guarded cleanup. Bail before doing any work, including the boot-time read.
        guard !isRestoring else {
            DiagnosticLog.shared.log("ClaudeTabs: restore already in progress — ignoring this trigger")
            return
        }
        isRestoring = true
        defer { isRestoring = false }
        if startupDelay > .zero { try? await Task.sleep(for: startupDelay) }

        // Everything decidable without talking to Ghostty is decided BEFORE the reader runs.
        // Reading the tabs sends an Apple event, and the first one puts up the "DevDeck wants to
        // control Ghostty" system prompt — which a user updating DevDeck would be seeing for a
        // feature that ships off and that they have never heard of. "Don't Allow" is the reasonable
        // answer to that question, and it kills the feature until they find it in System Settings.
        guard force || isEnabled() else {
            DiagnosticLog.shared.log("ClaudeTabs: not restoring — restore is off")
            return
        }
        let stored = store.load()
        guard let stored, !stored.tabs.isEmpty else {
            DiagnosticLog.shared.log("ClaudeTabs: not restoring — "
                + (stored == nil ? "no snapshot" : "snapshot is empty"))
            if force { lastError = L10n.claudeTabsNothingToRestore }
            return
        }

        let currentBoot = bootTime.bootTime()
        let restored = defaults.object(forKey: Self.restoredBootTimeKey) as? Date
        let reader = self.reader
        let openTabCount = await Task.detached(priority: .userInitiated) { reader.readTabs() }
            .value.openTabCount
        let decision = RestorePlanner.decide(snapshot: stored,
                                             enabled: isEnabled(),
                                             currentBootTime: currentBoot,
                                             restoredBootTime: restored,
                                             openTabCount: openTabCount,
                                             force: force)
        switch decision {
        case let .skip(reason):
            DiagnosticLog.shared.log("ClaudeTabs: not restoring — \(reason)")
            // A forced restore is a button press. It must never be a silent no-op.
            if force { lastError = L10n.claudeTabsNothingToRestore }
        case let .restore(actions):
            DiagnosticLog.shared.log("ClaudeTabs: restoring \(actions.count) tab(s)")
            let outcome = await restorer.restore(actions)
            // The boot is marked resolved as soon as ANYTHING opened, not only when everything did:
            // re-running the restore at that point would duplicate the tabs already on screen. Only
            // when NOTHING opened — the dominant failure being Automation not yet granted — must the
            // boot stay unmarked, so a retry after the user fixes it is clean.
            if outcome.succeeded > 0 {
                defaults.set(currentBoot, forKey: Self.restoredBootTimeKey)
            }
            // A partial failure is still a failure worth seeing, even though the boot is resolved.
            lastError = outcome.failed > 0 ? L10n.claudeTabsRestoreFailed : nil
            // One authoritative capture of the finished state, since the timer was suppressed for
            // the whole restore and would otherwise leave a half-restored snapshot in place.
            // Never after a *forced* restore: the tabs on screen are then the snapshot's tabs on
            // top of whatever was already open, and baking that in would make the next reboot
            // restore everything twice.
            if outcome.succeeded > 0 && !force {
                await capture(explicit: false, previousSignature: lastSignature)
            }
        }
    }
}

private extension GhosttyTabsResult {
    /// How many tabs the planner may count on. Not-running and failed both mean "we do not know",
    /// and the planner treats 0 as "no positive knowledge that exactly one tab exists" — which is
    /// what keeps it from typing into a tab that may not be there.
    var openTabCount: Int {
        switch self {
        case let .tabs(tabs): return tabs.count
        case .notRunning, .failed: return 0
        }
    }
}
