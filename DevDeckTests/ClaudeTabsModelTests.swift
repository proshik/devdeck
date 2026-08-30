import XCTest
@testable import DevDeck

/// The restore-and-capture flow properties that only show up once the model actually executes:
/// a failed restore must stay retryable, a second trigger must never overlap the first, a Ghostty
/// that was already running must still get a restore, and — the one that cannot be undone — a
/// snapshot from a previous boot must survive until this boot's restore has been resolved.
/// `UserDefaults.standard` is never touched: each test gets its own private suite standing in for
/// it, torn down afterwards.
@MainActor
final class ClaudeTabsModelTests: XCTestCase {

    private struct FakeGhosttyTabReader: GhosttyTabReading {
        var result: GhosttyTabsResult
        func readTabs() -> GhosttyTabsResult { result }
    }

    private struct FakeTranscriptIndex: TranscriptIndexing {
        var byDirectory: [String: [TranscriptTitle]] = [:]
        func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle] {
            byDirectory[workingDirectory] ?? []
        }
    }

    private struct FakeBootTime: BootTimeProviding {
        let now: Date
        func bootTime() -> Date { now }
    }

    private let restoredBootTimeKey = "claudeTabs.restoredBootTime"
    private let lastBoot = Date(timeIntervalSince1970: 1_000)
    private let currentBoot = Date(timeIntervalSince1970: 2_000)

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude-tabs.json")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ClaudeTabsModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    private func entry(_ n: Int) -> ClaudeTabEntry {
        ClaudeTabEntry(order: n, title: "t\(n)", workingDirectory: "/tmp/\(n)", sessionID: "s\(n)")
    }

    private func tab(_ n: Int) -> GhosttyTab {
        GhosttyTab(windowID: "w1", index: n, title: "t\(n)", workingDirectory: "/tmp/\(n)")
    }

    /// A model whose planner will decide `.restore`: a snapshot from an earlier boot, tabs open in
    /// Ghostty, and the current boot fixed. The transcript index resolves nothing, so a capture
    /// after the restore writes nothing — which is exactly what `SnapshotPolicy` promises.
    private func makeModel(tabs: Int = 1,
                           runnerResult: Bool = true,
                           stepDelay: Duration = .zero,
                           enabled: Bool = true,
                           ghosttyRunning: Bool = true,
                           snapshotBoot: Date? = nil,
                           emptyStore: Bool = false,
                           reader: GhosttyTabReading? = nil,
                           index: TranscriptIndexing = FakeTranscriptIndex(),
                           defaults: UserDefaults)
        throws -> (model: ClaudeTabsModel, store: ClaudeTabsStore, runner: TabRestorerTests.FakeAppleScriptRunner) {
        let store = ClaudeTabsStore(url: tempURL())
        if !emptyStore {
            try store.save(ClaudeTabsSnapshot(bootTime: snapshotBoot ?? lastBoot, capturedAt: lastBoot,
                                              tabs: (0..<tabs).map(entry)))
        }
        let runner = TabRestorerTests.FakeAppleScriptRunner()
        runner.result = runnerResult
        let model = ClaudeTabsModel(
            reader: reader ?? FakeGhosttyTabReader(result: .tabs((0..<tabs).map(tab))),
            index: index, store: store,
            bootTime: FakeBootTime(now: currentBoot),
            restorer: TabRestorer(runner: runner,
                                  sessions: FakeBackgroundSessions(ids: []),
                                  stepDelay: stepDelay),
            defaults: defaults,
            isEnabled: { enabled },
            isGhosttyRunning: { ghosttyRunning })
        return (model, store, runner)
    }

    // MARK: - Restore

    func testFailedRestoreDoesNotMarkTheBootRestored() async throws {
        let defaults = makeDefaults()
        let model = try makeModel(runnerResult: false, defaults: defaults).model

        model.restoreNow()
        await sleepUntil({ model.lastError != nil }, message: "the failed restore never finished")

        XCTAssertNil(defaults.object(forKey: restoredBootTimeKey),
                     "a failed restore must stay retryable on the next Ghostty launch")
    }

    func testSuccessfulRestoreMarksTheCurrentBoot() async throws {
        let defaults = makeDefaults()
        let model = try makeModel(defaults: defaults).model

        model.restoreNow()
        await sleepUntil({ defaults.object(forKey: restoredBootTimeKey) != nil },
                         message: "a successful restore never wrote restoredBootTime")

        XCTAssertEqual(defaults.object(forKey: restoredBootTimeKey) as? Date, currentBoot)
    }

    /// The second trigger has to be dropped, not queued: two restores running over each other
    /// would double every tab on screen.
    func testASecondTriggerNeverOverlapsTheFirst() async throws {
        let defaults = makeDefaults()
        let (model, _, runner) = try makeModel(tabs: 3, stepDelay: .milliseconds(100), defaults: defaults)

        model.restoreNow()
        await sleepUntil({ runner.calls.count >= 1 }, message: "the first restore never started")
        model.restoreNow()   // must be ignored — the first one is still running
        await sleepUntil({ defaults.object(forKey: restoredBootTimeKey) != nil },
                         message: "the first restore never finished")
        try await Task.sleep(for: .milliseconds(300))   // a second run would land in this window

        XCTAssertEqual(runner.calls.count, 3, "the second trigger restored the tabs a second time")
    }

    /// The user reboots and opens Ghostty before DevDeck's login item gets there: no launch
    /// notification ever arrives, so without this check nothing is ever restored — and the next
    /// capture stamps the snapshot with the current boot, losing the tabs for good.
    func testRestoresWhenGhosttyWasAlreadyRunning() async throws {
        let defaults = makeDefaults()
        let model = try makeModel(defaults: defaults).model

        model.restoreIfGhosttyAlreadyRunning()

        await sleepUntil({ defaults.object(forKey: restoredBootTimeKey) != nil },
                         message: "an already-running Ghostty never triggered a restore")
    }

    func testDoesNotRestoreWhenGhosttyIsNotRunning() async throws {
        let defaults = makeDefaults()
        let (model, _, runner) = try makeModel(ghosttyRunning: false, defaults: defaults)

        model.restoreIfGhosttyAlreadyRunning()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertTrue(runner.calls.isEmpty)
        XCTAssertNil(defaults.object(forKey: restoredBootTimeKey))
    }

    /// A restore the user asked for must not be baked into the snapshot: the tabs on screen are
    /// then the snapshot's tabs on top of whatever was already open, and capturing that would make
    /// the next reboot restore everything twice.
    func testForcedRestoreDoesNotRecapture() async throws {
        let defaults = makeDefaults()
        let index = FakeTranscriptIndex(byDirectory: [
            "/tmp/0": [TranscriptTitle(aiTitle: "t0", sessionID: "s0", modifiedAt: currentBoot)]
        ])
        let (model, store, _) = try makeModel(index: index, defaults: defaults)

        model.restoreNow()
        await sleepUntil({ defaults.object(forKey: restoredBootTimeKey) != nil },
                         message: "the forced restore never finished")
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(store.load()?.bootTime, lastBoot,
                       "a forced restore re-captured and stamped the snapshot with this boot")
    }

    /// Nine of ten tabs coming back is not "nothing opened": the boot must still be marked
    /// resolved (a retry would duplicate the nine), the failure must still be visible, and —
    /// what used to be the actual bug — automatic capture must unfreeze rather than stay held for
    /// the rest of the boot.
    func testPartiallyFailedRestoreStillMarksTheBootAndUnfreezesCapture() async throws {
        let defaults = makeDefaults()
        let index = FakeTranscriptIndex(byDirectory: [
            "/tmp/1": [TranscriptTitle(aiTitle: "t1", sessionID: "s1", modifiedAt: currentBoot)]
        ])
        let (model, store, runner) = try makeModel(tabs: 3, index: index, defaults: defaults)
        runner.failingCalls = [1]

        model.restoreNow()
        await sleepUntil({ defaults.object(forKey: restoredBootTimeKey) != nil },
                         message: "a partially failed restore never marked the boot restored")
        XCTAssertEqual(defaults.object(forKey: restoredBootTimeKey) as? Date, currentBoot,
                       "one failed action out of three must not stop the boot from being resolved")
        XCTAssertEqual(model.lastError, L10n.claudeTabsRestoreFailed,
                       "a partial failure must still be reported")

        // The write above is only half the fix — prove the invariant that actually gates the
        // automatic path was lifted, not just that the bookkeeping key changed.
        await model.captureIfEnabled()
        XCTAssertEqual(store.load()?.bootTime, currentBoot,
                       "a resolved boot must let the automatic capture through")
    }

    // MARK: - Capture

    /// THE invariant: the snapshot is from an earlier boot and nothing has restored it yet, so it
    /// is the only copy of the user's tabs. Capturing over it is unrecoverable.
    func testCaptureRefusesToOverwriteAnUnrestoredSnapshot() async throws {
        let defaults = makeDefaults()
        let index = FakeTranscriptIndex(byDirectory: [
            "/tmp/0": [TranscriptTitle(aiTitle: "t0", sessionID: "s0", modifiedAt: currentBoot)]
        ])
        let (model, store, _) = try makeModel(index: index, defaults: defaults)

        await model.captureIfEnabled()

        XCTAssertEqual(store.load()?.bootTime, lastBoot)
    }

    func testCaptureWritesOnceTheBootHasBeenRestored() async throws {
        let defaults = makeDefaults()
        defaults.set(currentBoot, forKey: restoredBootTimeKey)
        let index = FakeTranscriptIndex(byDirectory: [
            "/tmp/0": [TranscriptTitle(aiTitle: "t0", sessionID: "s0", modifiedAt: currentBoot)]
        ])
        let (model, store, _) = try makeModel(index: index, defaults: defaults)

        await model.captureIfEnabled()

        XCTAssertEqual(store.load()?.bootTime, currentBoot)
    }

    /// The very first snapshot of all: there is nothing to protect, so the invariant must not
    /// block it — otherwise the feature could never take its first snapshot.
    func testCaptureWritesTheFirstSnapshotOfAll() async throws {
        let defaults = makeDefaults()
        let index = FakeTranscriptIndex(byDirectory: [
            "/tmp/0": [TranscriptTitle(aiTitle: "t0", sessionID: "s0", modifiedAt: currentBoot)]
        ])
        let (model, store, _) = try makeModel(emptyStore: true, index: index, defaults: defaults)

        await model.captureIfEnabled()

        XCTAssertEqual(store.load()?.tabs.map(\.sessionID), ["s0"])
    }

    func testCaptureDoesNothingWhenTheFeatureIsOff() async throws {
        let defaults = makeDefaults()
        defaults.set(currentBoot, forKey: restoredBootTimeKey)
        let (model, store, _) = try makeModel(enabled: false, emptyStore: true, defaults: defaults)

        await model.captureIfEnabled()

        XCTAssertNil(store.load())
    }

    // MARK: - Holding an earlier boot's snapshot (UI confirmation gate)

    /// The exact condition `mayOverwriteSnapshot()` uses to hold the snapshot, mirrored read-only
    /// for the UI: `ClaudeTabsSectionView`/`ClaudeTabsView` confirm before "Capture now" when this
    /// is true, since that press would otherwise silently destroy the only copy of the pre-reboot
    /// tabs.
    func testIsHoldingEarlierBootSnapshotWhileUnrestored() async throws {
        let defaults = makeDefaults()
        let (model, _, _) = try makeModel(defaults: defaults)

        XCTAssertTrue(model.isHoldingEarlierBootSnapshot,
                      "an earlier boot's un-restored snapshot is the only copy of the user's tabs")
    }

    func testIsHoldingEarlierBootSnapshotIsFalseOnceRestored() async throws {
        let defaults = makeDefaults()
        defaults.set(currentBoot, forKey: restoredBootTimeKey)
        let (model, _, _) = try makeModel(defaults: defaults)

        XCTAssertFalse(model.isHoldingEarlierBootSnapshot,
                       "once this boot's restore is resolved there is nothing left to protect")
    }

    func testIsHoldingEarlierBootSnapshotIsFalseWithNoSnapshotAtAll() async throws {
        let defaults = makeDefaults()
        let (model, _, _) = try makeModel(emptyStore: true, defaults: defaults)

        XCTAssertFalse(model.isHoldingEarlierBootSnapshot, "nothing to lose means nothing to confirm")
    }

    // MARK: - Reporting

    /// "Ghostty is not running" is the normal state of a Mac with no terminal open: silent on the
    /// automatic path, answered on the explicit one, because there a user is waiting for a reply.
    func testAutomaticCaptureStaysSilentWhenGhosttyIsNotRunning() async throws {
        let defaults = makeDefaults()
        defaults.set(currentBoot, forKey: restoredBootTimeKey)
        let (model, _, _) = try makeModel(reader: FakeGhosttyTabReader(result: .notRunning),
                                          defaults: defaults)

        await model.captureIfEnabled()

        XCTAssertNil(model.lastError)
    }

    func testExplicitCaptureReportsThatGhosttyIsNotRunning() async throws {
        let defaults = makeDefaults()
        let (model, _, _) = try makeModel(reader: FakeGhosttyTabReader(result: .notRunning),
                                          defaults: defaults)

        model.captureNow()

        await sleepUntil({ model.lastError != nil }, message: "\"Capture now\" said nothing at all")
        XCTAssertEqual(model.lastError, L10n.claudeTabsGhosttyNotRunning)
    }

    /// A denied Automation permission used to look exactly like "no terminal open" — both were nil.
    func testAFailedReadIsAlwaysReported() async throws {
        let defaults = makeDefaults()
        defaults.set(currentBoot, forKey: restoredBootTimeKey)
        let (model, _, _) = try makeModel(
            reader: FakeGhosttyTabReader(result: .failed("Not authorized to send Apple events")),
            defaults: defaults)

        await model.captureIfEnabled()

        XCTAssertEqual(model.lastError,
                       L10n.claudeTabsCaptureFailed("Not authorized to send Apple events"))
    }
}
