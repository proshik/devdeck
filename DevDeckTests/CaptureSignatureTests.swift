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

    /// Same idea as `ResolvingIndex`, but counting — the one fake both
    /// `testAutomaticCaptureSkipsAnUnchangedTabSet` and
    /// `testExplicitCaptureAlwaysRunsEvenOnAnUnchangedTabSet` share, so the "0 more calls" vs
    /// "1 more call" contrast between them is the intended distinction, not an artifact of using
    /// two different fakes.
    private final class CountingResolvingIndex: TranscriptIndexing, @unchecked Sendable {
        private(set) var calls = 0
        var title: TranscriptTitle
        init(title: TranscriptTitle) { self.title = title }
        func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle] {
            calls += 1
            return [title]
        }
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

        let outcome = ClaudeTabsModel.collect(reader: FakeReader(result: .tabs(tabs)),
                                              index: index,
                                              previousSignature: tabs)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(index.calls, 0, "an unchanged tab set must not touch the transcripts")
    }

    func testChangedTitleResolvesAgain() {
        let before = [GhosttyTab(windowID: "w1", index: 1, title: "✳ a", workingDirectory: "/tmp/a")]
        let after = [GhosttyTab(windowID: "w1", index: 1, title: "✳ renamed", workingDirectory: "/tmp/a")]
        let index = CountingIndex()

        let outcome = ClaudeTabsModel.collect(reader: FakeReader(result: .tabs(after)),
                                              index: index,
                                              previousSignature: before)

        guard case .entries = outcome else { return XCTFail("expected a fresh resolve") }
        XCTAssertEqual(index.calls, 1)
    }

    /// Fix for a real bug: the old `signature(of:)` joined `"\(windowID)\t\(index)\t\(title)\t\(cwd)"`,
    /// so a tab character inside the title could shift the field boundaries and make two DIFFERENT
    /// tab sets produce the identical string — here, `title: "a\tb", cwd: "/tmp/x"` and
    /// `title: "a", cwd: "b\t/tmp/x"` both joined to `"w1\t1\ta\tb\t/tmp/x"`. Comparing `[GhosttyTab]`
    /// directly, as `collect` does now, cannot fall into that trap.
    func testATabCharacterInATitleDoesNotMaskADifferentTabSet() {
        let before = [GhosttyTab(windowID: "w1", index: 1, title: "a\tb", workingDirectory: "/tmp/x")]
        let after = [GhosttyTab(windowID: "w1", index: 1, title: "a", workingDirectory: "b\t/tmp/x")]
        let index = CountingIndex()

        let outcome = ClaudeTabsModel.collect(reader: FakeReader(result: .tabs(after)),
                                              index: index,
                                              previousSignature: before)

        guard case .entries = outcome else {
            return XCTFail("a tab character in the title made two different tab sets compare equal")
        }
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

    /// A model with one tab that always resolves, backed by a `CountingResolvingIndex` — set up
    /// so the FIRST capture through it (whichever path the caller drives) establishes a baseline
    /// signature by actually persisting, and a SECOND capture over the exact same tab set is the
    /// one under test.
    private func makeCapturingModel() -> (model: ClaudeTabsModel, index: CountingResolvingIndex) {
        let tab = GhosttyTab(windowID: "w1", index: 1, title: "✳ a", workingDirectory: "/tmp/a")
        let index = CountingResolvingIndex(title: TranscriptTitle(aiTitle: "a", sessionID: "s1",
                                                                   modifiedAt: Date()))
        let model = ClaudeTabsModel(reader: FakeReader(result: .tabs([tab])),
                                    index: index,
                                    store: ClaudeTabsStore(url: tempStoreURL()),
                                    bootTime: FixedBootTime(date: Date(timeIntervalSince1970: 1_000)),
                                    defaults: makeDefaults(),
                                    isEnabled: { true })
        return (model, index)
    }

    /// The automatic path is the one whose whole purpose is to cost nothing when nothing changed:
    /// a second automatic capture over an unchanged tab set must add ZERO transcript-index calls.
    func testAutomaticCaptureSkipsAnUnchangedTabSet() async throws {
        let (model, index) = makeCapturingModel()

        await model.captureIfEnabled()
        let callsAfterFirstCapture = index.calls
        XCTAssertEqual(callsAfterFirstCapture, 1, "the priming capture should have resolved once")

        await model.captureIfEnabled()

        XCTAssertEqual(index.calls, callsAfterFirstCapture,
                       "the automatic path re-read the transcripts for an unchanged tab set")
    }

    /// The counterpart pinning the fix: "Capture now" must never go quiet. An unchanged tab set is
    /// exactly the case a user is most likely to hit when they press the button — right after an
    /// automatic capture already ran — so the explicit path must add exactly ONE more
    /// transcript-index call and one more write, not silently agree with the automatic path that
    /// there is nothing to do.
    func testExplicitCaptureAlwaysRunsEvenOnAnUnchangedTabSet() async throws {
        let (model, index) = makeCapturingModel()

        await model.captureIfEnabled()
        let callsAfterFirstCapture = index.calls
        XCTAssertEqual(callsAfterFirstCapture, 1, "the priming capture should have resolved once")
        let firstCapturedAt = try XCTUnwrap(model.snapshot?.capturedAt)

        try await Task.sleep(for: .milliseconds(30))
        model.captureNow()
        await sleepUntil({ index.calls == callsAfterFirstCapture + 1 },
                         message: "\"Capture now\" skipped the transcript pass on an unchanged tab set")

        XCTAssertEqual(index.calls, callsAfterFirstCapture + 1,
                       "\"Capture now\" must always run a real capture, even when nothing changed")
        let secondCapturedAt = try XCTUnwrap(model.snapshot?.capturedAt)
        XCTAssertGreaterThan(secondCapturedAt, firstCapturedAt,
                            "\"Capture now\" must visibly refresh the snapshot, not silently no-op")
        XCTAssertNil(model.lastError)
    }
}
