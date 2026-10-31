import AppKit
import XCTest
@testable import DevDeck

@MainActor private final class ClipboardFakePasteboard: ClipboardPasteboard {
    var changeCount = 0
    var access: ClipboardAccess = .allowed
    var value = ClipboardSnapshot(text: nil)
    var reads = 0
    var copied: ClipboardEntry?
    func snapshot(excludedBundleIDs: Set<String>) -> ClipboardSnapshot? { reads += 1; return value }
    func write(_ entry: ClipboardEntry) -> Int? { copied = entry; changeCount += 1; value.text = entry.text; return changeCount }
    func requestAccess() { access = .allowed }
    func external(_ text: String, types: Set<String> = [], source: String? = nil, active: String? = nil) {
        changeCount += 1
        value = ClipboardSnapshot(text: text, sourceBundleID: source, types: types, activeBundleID: active)
    }
}

@MainActor final class ClipboardModelTests: XCTestCase {
    private func make() -> (ClipboardModel, ClipboardFakePasteboard, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let board = ClipboardFakePasteboard()
        let model = ClipboardModel(history: ClipboardHistory(storage: ClipboardFileStorage(directory: directory)), pasteboard: board)
        return (model, board, directory)
    }
    func testDisabledPausedAndResumedCollectionDoNotCaptureOlderClipboard() async throws {
        let (model, board, directory) = make(); defer { try? FileManager.default.removeItem(at: directory) }
        await model.synchronize(.init())
        board.external("disabled")
        await model.poll()
        XCTAssertTrue(model.entries.isEmpty)
        var settings = ClipboardSettings(); settings.enabled = true
        await model.synchronize(settings)
        await model.poll()
        XCTAssertTrue(model.entries.isEmpty, "enabling must baseline, not collect old clipboard")
        board.external("first")
        await model.poll()
        XCTAssertEqual(model.entries.map(\.text), ["first"])
        settings.paused = true; await model.synchronize(settings)
        board.external("paused"); await model.poll()
        settings.paused = false; await model.synchronize(settings); await model.poll()
        XCTAssertEqual(model.entries.map(\.text), ["first"])
        board.external("resumed"); await model.poll()
        XCTAssertEqual(model.entries.map(\.text), ["resumed", "first"])
    }
    func testExclusionsAndSensitiveTypesSkipTextWithoutFalseSourceAttribution() async throws {
        let (model, board, directory) = make(); defer { try? FileManager.default.removeItem(at: directory) }
        var settings = ClipboardSettings(); settings.enabled = true; settings.excludedBundleIDs = ["com.example.passwords"]
        await model.synchronize(settings)
        board.external("secret", types: ["org.nspasteboard.ConcealedType"]); await model.poll()
        board.external("secret", source: "com.example.passwords"); await model.poll()
        board.external("secret", active: "com.example.passwords"); await model.poll()
        board.external("/some/file", types: [NSPasteboard.PasteboardType.fileURL.rawValue]); await model.poll()
        XCTAssertTrue(model.entries.isEmpty)
        board.external("unknown", active: "com.example.editor"); await model.poll()
        let entry = try XCTUnwrap(model.entries.first)
        XCTAssertNil(entry.sourceBundleID, "frontmost application is not proof of clipboard ownership")
        XCTAssertEqual(entry.text, "unknown")
    }
    func testOwnCopyDoesNotDuplicateAndSearchPreservesText() async throws {
        let (model, board, directory) = make(); defer { try? FileManager.default.removeItem(at: directory) }
        var settings = ClipboardSettings(); settings.enabled = true
        await model.synchronize(settings)
        board.external("kubectl\nget pods"); await model.poll()
        let first = try XCTUnwrap(model.entries.first)
        board.external("another"); await model.poll()
        model.copy(first); await model.poll()
        XCTAssertEqual(model.entries.count, 2)
        XCTAssertEqual(board.copied?.text, "kubectl\nget pods")
        XCTAssertEqual(model.search("KUBECTL").map(\.id), [first.id])
        await model.setPinned(first)
        XCTAssertEqual(model.search("", pinnedOnly: true).map(\.id), [first.id])
    }
    func testDeniedAccessDoesNotReadAndPermissionChangeStartsAtCurrentContent() async throws {
        let (model, board, directory) = make(); defer { try? FileManager.default.removeItem(at: directory) }
        board.access = .denied
        var settings = ClipboardSettings(); settings.enabled = true
        await model.synchronize(settings)
        board.external("private"); await model.poll()
        XCTAssertEqual(board.reads, 0)
        board.access = .allowed; await model.poll()
        XCTAssertTrue(model.entries.isEmpty)
        board.external("allowed"); await model.poll()
        XCTAssertEqual(model.entries.map(\.text), ["allowed"])
    }
    func testNamedNativePasteboardRoundTripsTextAndSourceWithoutTouchingUserClipboard() async throws {
        let native = NSPasteboard(name: .init("DevDeck-test-\(UUID().uuidString)"))
        defer { native.releaseGlobally() }
        let adapter = SystemClipboardPasteboard(pasteboard: native)
        let entry = ClipboardEntry(text: "native\ntext", sourceBundleID: "com.example.app")
        XCTAssertNotNil(adapter.write(entry))
        let snapshot = try XCTUnwrap(adapter.snapshot(excludedBundleIDs: []))
        XCTAssertEqual(snapshot.text, "native\ntext")
        XCTAssertEqual(snapshot.sourceBundleID, "com.example.app")
        XCTAssertNil(adapter.snapshot(excludedBundleIDs: ["com.example.app"]))
        let item = NSPasteboardItem(); item.setString("hidden", forType: .string)
        item.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        native.clearContents(); native.writeObjects([item])
        XCTAssertNil(adapter.snapshot(excludedBundleIDs: []))
    }
}

extension ClipboardModelTests {
    func testBackgroundCollectorRunsWithNoViewAndRemainsIndependentOfPanelVisibility() async throws {
        let (model, board, directory) = make(); defer { model.stop(); try? FileManager.default.removeItem(at: directory) }
        var settings = ClipboardSettings(); settings.enabled = true
        await model.synchronize(settings)
        model.start(settings: { settings })
        board.external("background")
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(model.entries.map(\.text), ["background"])
        let store = CommandStore(configURL: directory.appendingPathComponent("config.json"))
        try store.save(.empty)
        store.updateClipboard { $0.enabled = true }
        store.updatePanel { $0.removeModule(.clipboard); $0.removeSection(.clipboard) }
        board.external("hidden module")
        try await Task.sleep(for: .milliseconds(1_200))
        XCTAssertEqual(model.entries.map(\.text), ["hidden module", "background"])
        XCTAssertTrue(store.config.settings.clipboard.enabled)
        let disk = try String(contentsOf: directory.appendingPathComponent("config.json"), encoding: .utf8)
        XCTAssertFalse(disk.contains("background")); XCTAssertFalse(disk.contains("hidden module"))
    }
    func testOldConfigDisablesHistoryAndNormalizesUnsafeLimits() throws {
        let old = try ConfigCodec.decode(Data("{}".utf8))
        XCTAssertFalse(old.settings.clipboard.enabled)
        XCTAssertEqual(old.panel.sections.last?.modules.map(\.id), ["clipboard"])
        let edited = try ConfigCodec.decode(Data(#"{"settings":{"clipboard":{"enabled":true,"maxEntries":-1,"retentionDays":999999,"maxBytes":0}},"panel":{"sections":[],"removedModuleIDs":["clipboard"],"removedSectionIDs":["clipboard"]}}"#.utf8))
        XCTAssertEqual(edited.settings.clipboard.maxEntries, 1)
        XCTAssertEqual(edited.settings.clipboard.retentionDays, 365)
        XCTAssertEqual(edited.settings.clipboard.maxBytes, 1_024)
        XCTAssertFalse(edited.panel.sections.contains { $0.id == "clipboard" })
        XCTAssertEqual(try ConfigCodec.decode(ConfigCodec.encode(edited)), edited)
    }
}

extension ClipboardModelTests {
    func testRestartWithLimitsBelowSavedPinsStillShowsEntriesForRecovery() async throws {
        let (model, board, directory) = make(); defer { try? FileManager.default.removeItem(at: directory) }
        var settings = ClipboardSettings(); settings.enabled = true
        await model.synchronize(settings)
        board.external("first"); await model.poll()
        await model.setPinned(try XCTUnwrap(model.entries.first))
        board.external("second"); await model.poll()
        await model.setPinned(try XCTUnwrap(model.entries.first))
        let restarted = ClipboardModel(history: ClipboardHistory(storage: ClipboardFileStorage(directory: directory)), pasteboard: board)
        settings.maxEntries = 1
        await restarted.synchronize(settings)
        XCTAssertEqual(restarted.entries.map(\.text), ["second", "first"], "a budget error must still expose saved pins so the user can recover without clearing all history")
        XCTAssertNotNil(restarted.errorMessage)
        let oldest = try XCTUnwrap(restarted.entries.last)
        await restarted.setPinned(oldest)
        await restarted.synchronize(settings)
        XCTAssertEqual(restarted.entries.map(\.text), ["second"])
        XCTAssertNil(restarted.errorMessage)
    }
}

private final class PausingClipboardStorage: ClipboardHistoryStorage, @unchecked Sendable {
    private let lock = NSLock()
    private var data: Data?
    private var pause = false
    let entered = XCTestExpectation(description: "storage write suspended")
    let gate = DispatchSemaphore(value: 0)
    func pauseNextWrite() { lock.lock(); pause = true; lock.unlock() }
    func read() throws -> Data? { lock.lock(); defer { lock.unlock() }; return data }
    func write(_ value: Data) throws {
        lock.lock(); let shouldPause = pause; pause = false; lock.unlock()
        if shouldPause {
            entered.fulfill()
            guard gate.wait(timeout: .now() + 3) == .success else { throw ClipboardHistoryError.writeFailed }
        }
        lock.lock(); data = value; lock.unlock()
    }
}

extension ClipboardModelTests {
    func testConfirmedClearWaitsForCaptureAndPreservesChosenPinnedPolicy() async throws {
        for includingPinned in [false, true] {
            let storage = PausingClipboardStorage()
            let board = ClipboardFakePasteboard()
            let model = ClipboardModel(history: ClipboardHistory(storage: storage), pasteboard: board)
            var settings = ClipboardSettings(); settings.enabled = true
            await model.synchronize(settings)
            board.external("pinned"); await model.poll()
            await model.setPinned(try XCTUnwrap(model.entries.first))
            storage.pauseNextWrite()
            board.external("capturing")
            let capture = Task { await model.poll() }
            await fulfillment(of: [storage.entered], timeout: 2)
            let invoked = XCTestExpectation(description: "clear invoked while busy")
            let clear = Task { invoked.fulfill(); await model.clear(includingPinned: includingPinned) }
            await fulfillment(of: [invoked], timeout: 2)
            storage.gate.signal()
            await capture.value; await clear.value
            XCTAssertEqual(model.entries.map(\.text), includingPinned ? [] : ["pinned"])
            XCTAssertFalse(model.isBusy)
        }
    }
}

extension ClipboardModelTests {
    func testQueuedPinAndRemovalCompleteBeforeFollowingClear() async throws {
        let storage = PausingClipboardStorage()
        let board = ClipboardFakePasteboard()
        let model = ClipboardModel(history: ClipboardHistory(storage: storage), pasteboard: board)
        var settings = ClipboardSettings(); settings.enabled = true
        await model.synchronize(settings)
        board.external("keep"); await model.poll()
        let keep = try XCTUnwrap(model.entries.first)
        board.external("remove"); await model.poll()
        let remove = try XCTUnwrap(model.entries.first)
        await model.setPinned(remove)
        storage.pauseNextWrite(); board.external("capturing")
        let capture = Task { await model.poll() }
        await fulfillment(of: [storage.entered], timeout: 2)
        let pinQueued = XCTestExpectation(description: "pin queued")
        let pin = Task { pinQueued.fulfill(); await model.setPinned(keep) }
        await fulfillment(of: [pinQueued], timeout: 2)
        let removalQueued = XCTestExpectation(description: "removal queued")
        let removal = Task { removalQueued.fulfill(); await model.remove(remove) }
        await fulfillment(of: [removalQueued], timeout: 2)
        let clearQueued = XCTestExpectation(description: "clear queued")
        let clear = Task { clearQueued.fulfill(); await model.clear(includingPinned: false) }
        await fulfillment(of: [clearQueued], timeout: 2)
        storage.gate.signal()
        await capture.value; await pin.value; await removal.value; await clear.value
        XCTAssertEqual(model.entries.map(\.text), ["keep"])
        XCTAssertEqual(model.entries.first?.isPinned, true)
        XCTAssertFalse(model.isBusy)
    }
}
