import XCTest
@testable import DevDeck

/// The two-phase capture: an unchanged tab set must cost one AppleScript read and NOTHING else.
/// The counting fake is the point — without it the test would pass against an implementation that
/// re-read every transcript and then threw the result away.
@MainActor
final class CaptureSignatureTests: XCTestCase {

    private struct FakeReader: GhosttyTabReading {
        var result: GhosttyTabsResult
        func readTabs() -> GhosttyTabsResult { result }
    }

    private final class CountingIndex: TranscriptIndexing, @unchecked Sendable {
        private(set) var calls = 0
        func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle] {
            calls += 1
            return []
        }
    }

    /// Resolves every tab it is asked about to the same fixed session, so a capture through it
    /// clears `SnapshotPolicy.shouldPersist` and actually reaches the store.
    private struct ResolvingIndex: TranscriptIndexing {
        var title: TranscriptTitle
        func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle] { [title] }
    }

    private struct FixedBootTime: BootTimeProviding {
        let date: Date
        func bootTime() -> Date { date }
    }

    private func tempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude-tabs.json")
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "CaptureSignatureTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func testClampsBothEnds() {
        XCTAssertEqual(ClaudeTabsCaptureInterval.clamped(0), 5)
        XCTAssertEqual(ClaudeTabsCaptureInterval.clamped(86_400), 300)
        XCTAssertEqual(ClaudeTabsCaptureInterval.clamped(15), 15)
    }

    func testUnchangedTabSetSkipsTheTranscriptPass() {
        let tabs = [GhosttyTab(windowID: "w1", index: 1, title: "✳ a", workingDirectory: "/tmp/a")]
        let index = CountingIndex()
        let signature = ClaudeTabsModel.signature(of: tabs)

        let outcome = ClaudeTabsModel.collect(reader: FakeReader(result: .tabs(tabs)),
                                              index: index,
                                              previousSignature: signature)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(index.calls, 0, "an unchanged tab set must not touch the transcripts")
    }

    func testChangedTitleResolvesAgain() {
        let before = [GhosttyTab(windowID: "w1", index: 1, title: "✳ a", workingDirectory: "/tmp/a")]
        let after = [GhosttyTab(windowID: "w1", index: 1, title: "✳ renamed", workingDirectory: "/tmp/a")]
        let index = CountingIndex()

        let outcome = ClaudeTabsModel.collect(reader: FakeReader(result: .tabs(after)),
                                              index: index,
                                              previousSignature: ClaudeTabsModel.signature(of: before))

        guard case .entries = outcome else { return XCTFail("expected a fresh resolve") }
        XCTAssertEqual(index.calls, 1)
    }

    /// `apply(.unchanged)` must be a true no-op: not just "skips the transcript pass" (covered
    /// above) but "never touches the snapshot file" — no write, and so no new `capturedAt` and no
    /// new mtime, even though the second capture goes through the model end to end.
    func testUnchangedCaptureDoesNotRewriteTheSnapshotFile() async throws {
        let storeURL = tempStoreURL()
        let store = ClaudeTabsStore(url: storeURL)
        let tab = GhosttyTab(windowID: "w1", index: 1, title: "✳ a", workingDirectory: "/tmp/a")
        let index = ResolvingIndex(title: TranscriptTitle(aiTitle: "a", sessionID: "s1", modifiedAt: Date()))
        let model = ClaudeTabsModel(reader: FakeReader(result: .tabs([tab])),
                                    index: index,
                                    store: store,
                                    bootTime: FixedBootTime(date: Date(timeIntervalSince1970: 1_000)),
                                    defaults: makeDefaults(),
                                    isEnabled: { true })

        await model.captureIfEnabled()
        let firstContent = try Data(contentsOf: storeURL)
        let firstModified = try FileManager.default
            .attributesOfItem(atPath: storeURL.path)[.modificationDate] as? Date
        XCTAssertNotNil(model.snapshot, "the first capture with a matching session should have persisted")

        try await Task.sleep(for: .milliseconds(30))
        await model.captureIfEnabled()
        let secondContent = try Data(contentsOf: storeURL)
        let secondModified = try FileManager.default
            .attributesOfItem(atPath: storeURL.path)[.modificationDate] as? Date

        XCTAssertEqual(firstContent, secondContent, "an unchanged tab set rewrote the snapshot file")
        XCTAssertEqual(firstModified, secondModified, "an unchanged tab set touched the snapshot file's mtime")
    }
}
