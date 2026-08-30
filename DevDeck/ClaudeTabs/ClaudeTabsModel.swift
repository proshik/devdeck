import AppKit

enum SnapshotPolicy {
    /// Never overwrite a good snapshot with an empty one.
    static func shouldPersist(_ entries: [ClaudeTabEntry]) -> Bool { !entries.isEmpty }
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

    private(set) var snapshot: ClaudeTabsSnapshot?
    private(set) var lastError: String?

    private let reader: GhosttyTabReading
    private let index: TranscriptIndexing
    private let store: ClaudeTabsStore
    private let bootTime: BootTimeProviding
    private let restorer: TabRestorer
    private var isEnabled: () -> Bool = { false }
    private var timer: Timer?

    init(reader: GhosttyTabReading = LiveGhosttyTabReader(),
         index: TranscriptIndexing = LiveTranscriptIndex(),
         store: ClaudeTabsStore = ClaudeTabsStore(),
         bootTime: BootTimeProviding = LiveBootTime(),
         restorer: TabRestorer = TabRestorer()) {
        self.reader = reader
        self.index = index
        self.store = store
        self.bootTime = bootTime
        self.restorer = restorer
        self.snapshot = store.load()
    }

    func start(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureIfEnabled() }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.mitchellh.ghostty" else { return }
            Task { @MainActor in await self?.restoreAfterGhosttyLaunch() }
        }
        center.addObserver(forName: NSWorkspace.willPowerOffNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.captureIfEnabled() }
        }
    }

    func captureNow() { capture() }

    private func captureIfEnabled() {
        guard isEnabled() else { return }
        capture()
    }

    private func capture() {
        guard let tabs = reader.readTabs(), !tabs.isEmpty else { return }
        var titles: [String: [TranscriptTitle]] = [:]
        for directory in Set(tabs.map(\.workingDirectory)) {
            titles[directory] = index.titles(forWorkingDirectory: directory)
        }
        let entries = SessionResolver.resolve(tabs: tabs, titlesByDirectory: titles)
        guard SnapshotPolicy.shouldPersist(entries) else { return }

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

    /// Ghostty needs a moment to put up its first window before we can talk to it.
    private func restoreAfterGhosttyLaunch() async {
        try? await Task.sleep(for: .milliseconds(1500))
        await runRestore()
    }

    func restoreNow() { Task { await runRestore(force: true) } }

    private func runRestore(force: Bool = false) async {
        let currentBoot = bootTime.bootTime()
        let restored = UserDefaults.standard.object(forKey: Self.restoredBootTimeKey) as? Date
        let decision = RestorePlanner.decide(snapshot: store.load(),
                                             enabled: force || isEnabled(),
                                             currentBootTime: currentBoot,
                                             restoredBootTime: force ? nil : restored,
                                             openTabCount: reader.readTabs()?.count ?? 0)
        switch decision {
        case let .skip(reason):
            DiagnosticLog.shared.log("ClaudeTabs: not restoring — \(reason)")
        case let .restore(actions):
            DiagnosticLog.shared.log("ClaudeTabs: restoring \(actions.count) tab(s)")
            let ok = await restorer.restore(actions)
            UserDefaults.standard.set(currentBoot, forKey: Self.restoredBootTimeKey)
            lastError = ok ? nil : L10n.claudeTabsRestoreFailed
        }
    }
}
