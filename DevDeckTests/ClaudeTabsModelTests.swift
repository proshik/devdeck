import XCTest
@testable import DevDeck

/// The two restore-flow safety properties that only show up once `runRestore` actually executes:
/// a failed restore must stay retryable (Finding 1 of the task-8 review), and a second trigger
/// must never overlap the first (Finding 6). `UserDefaults.standard` is never touched — each test
/// gets its own private suite standing in for it, torn down afterwards.
@MainActor
final class ClaudeTabsModelTests: XCTestCase {

    private struct FakeGhosttyTabReader: GhosttyTabReading {
        var tabs: [GhosttyTab]?
        func readTabs() -> [GhosttyTab]? { tabs }
    }

    private struct FakeTranscriptIndex: TranscriptIndexing {
        func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle] { [] }
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

    /// A model whose planner will decide `.restore`: a one-tab snapshot from an earlier boot, one
    /// open Ghostty tab, and the flag forced on via `restoreNow()`.
    private func makeModel(runnerResult: Bool, defaults: UserDefaults) throws -> ClaudeTabsModel {
        let store = ClaudeTabsStore(url: tempURL())
        try store.save(ClaudeTabsSnapshot(
            bootTime: lastBoot, capturedAt: lastBoot,
            tabs: [ClaudeTabEntry(order: 0, title: "t", workingDirectory: "/tmp/a", sessionID: "s1")]))

        let runner = TabRestorerTests.FakeAppleScriptRunner()
        runner.result = runnerResult
        let reader = FakeGhosttyTabReader(tabs: [
            GhosttyTab(windowID: "w1", index: 0, title: "t", workingDirectory: "/tmp/a")
        ])

        return ClaudeTabsModel(reader: reader, index: FakeTranscriptIndex(), store: store,
                               bootTime: FakeBootTime(now: currentBoot),
                               restorer: TabRestorer(runner: runner, stepDelay: .zero),
                               defaults: defaults)
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "ClaudeTabsModelTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testFailedRestoreDoesNotMarkTheBootRestored() async throws {
        let defaults = makeDefaults()
        let model = try makeModel(runnerResult: false, defaults: defaults)

        model.restoreNow()
        await sleepUntil({ model.lastError != nil }, message: "the failed restore never finished")

        XCTAssertNil(defaults.object(forKey: restoredBootTimeKey),
                     "a failed restore must stay retryable on the next Ghostty launch")
    }

    func testSuccessfulRestoreMarksTheCurrentBoot() async throws {
        let defaults = makeDefaults()
        let model = try makeModel(runnerResult: true, defaults: defaults)

        model.restoreNow()
        await sleepUntil({ defaults.object(forKey: restoredBootTimeKey) != nil },
                         message: "a successful restore never wrote restoredBootTime")

        XCTAssertEqual(defaults.object(forKey: restoredBootTimeKey) as? Date, currentBoot)
    }
}
