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
    case entries([ClaudeTabEntry])
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
    private var timer: Timer?
    /// Set for the duration of a restore — including the delay it waits out before touching
    /// Ghostty — so the once-a-minute timer cannot capture a half-restored tab set and overwrite
    /// the snapshot with it. Also what keeps a second trigger (the launch observer firing twice, a
    /// "Restore now" press mid-restore) from racing the first (see `runRestore`).
    private var isRestoring = false
    /// So the "refusing to capture" line is logged once per state change, not once a minute.
    private var loggedCaptureHold = false

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

    func start(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.captureIfEnabled() }
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
    /// It does not bypass `isRestoring`. Pressing it during a restore — including the second and a
    /// half where Ghostty has opened its first tab and nothing has been restored into it yet —
    /// would snapshot a tab set that is not the user's, and the user has no way of seeing that a
    /// restore is under way. Refusing and saying so is the only honest answer.
    func captureNow() {
        guard !isRestoring else {
            lastError = L10n.claudeTabsRestoreInProgress
            return
        }
        Task { @MainActor in await capture(explicit: true) }
    }

    /// The automatic path — the once-a-minute timer. Respects the feature flag, is suppressed while
    /// a restore is in flight, and never overwrites a snapshot that is still owed a restore.
    func captureIfEnabled() async {
        guard isEnabled(), !isRestoring, mayOverwriteSnapshot() else { return }
        await capture(explicit: false)
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
        apply(Self.collect(reader: reader, index: index), explicit: false)
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
        guard let stored = store.load() else { return true }
        let currentBoot = bootTime.bootTime()
        let restored = defaults.object(forKey: Self.restoredBootTimeKey) as? Date
        guard !BootInstant.same(stored.bootTime, currentBoot),
              !BootInstant.same(currentBoot, restored) else {
            loggedCaptureHold = false
            return true
        }
        if !loggedCaptureHold {
            loggedCaptureHold = true
            DiagnosticLog.shared.log("ClaudeTabs: holding the snapshot — it is from an earlier boot "
                + "and has not been restored yet")
        }
        return false
    }

    /// Reads Ghostty and resolves the sessions **off the main actor**, then applies the result on
    /// it. The work behind `collect` forks `pgrep` and `osascript` and reads whole transcripts —
    /// on this machine 1.1 GB of them, with the active session's file changing mtime constantly —
    /// which is not something a menu-bar app may do to its own UI thread once a minute. Same
    /// treatment as `ProcessManager.refreshVMDisk` gives its blocking probes.
    private func capture(explicit: Bool) async {
        let reader = self.reader
        let index = self.index
        let outcome = await Task.detached(priority: .utility) {
            Self.collect(reader: reader, index: index)
        }.value
        apply(outcome, explicit: explicit)
    }

    /// Read + resolve, with nothing actor-bound in it, so the async path and the synchronous
    /// shutdown path run exactly the same code.
    private nonisolated static func collect(reader: GhosttyTabReading,
                                            index: TranscriptIndexing) -> CaptureOutcome {
        switch reader.readTabs() {
        case .notRunning:
            return .notRunning
        case let .failed(message):
            return .failed(message)
        case let .tabs(tabs):
            var titles: [String: [TranscriptTitle]] = [:]
            for directory in Set(tabs.map(\.workingDirectory)) {
                titles[directory] = index.titles(forWorkingDirectory: directory)
            }
            return .entries(SessionResolver.resolve(tabs: tabs, titlesByDirectory: titles))
        }
    }

    /// The main-actor half: the store write and the observable properties, nothing else.
    private func apply(_ outcome: CaptureOutcome, explicit: Bool) {
        switch outcome {
        case .notRunning:
            // Silent on the automatic path — a Mac with no terminal open is not an error. Reported
            // when the user pressed the button, because then it is the answer to their question.
            if explicit { lastError = L10n.claudeTabsGhosttyNotRunning }
        case let .failed(message):
            // Always surfaced: this is Automation being denied, and it is invisible everywhere else.
            lastError = L10n.claudeTabsCaptureFailed(message)
        case let .entries(entries):
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
            let ok = await restorer.restore(actions)
            // Only a successful restore marks the boot done: the dominant failure is Automation
            // not yet granted, which opens nothing, so a retry after the user fixes it is clean —
            // whereas marking it done unconditionally would forfeit the feature on the one run
            // (right after granting permission) where it matters most.
            if ok {
                defaults.set(currentBoot, forKey: Self.restoredBootTimeKey)
            }
            lastError = ok ? nil : L10n.claudeTabsRestoreFailed
            // One authoritative capture of the finished state, since the timer was suppressed for
            // the whole restore and would otherwise leave a half-restored snapshot in place.
            // Never after a *forced* restore: the tabs on screen are then the snapshot's tabs on
            // top of whatever was already open, and baking that in would make the next reboot
            // restore everything twice.
            if ok && !force {
                await capture(explicit: false)
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
