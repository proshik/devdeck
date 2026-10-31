import Foundation
import XCTest
@testable import DevDeck

private final class ClipboardMemoryStorage: ClipboardHistoryStorage, @unchecked Sendable {
    var data: Data?
    var failWrites = false
    func read() throws -> Data? { data }
    func write(_ data: Data) throws {
        if failWrites { throw ClipboardHistoryError.writeFailed }
        self.data = data
    }
}

final class ClipboardHistoryTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    func testCaptureSurvivesRestartWithoutConsecutiveDuplicates() async throws {
        let storage = ClipboardMemoryStorage()
        let history = ClipboardHistory(storage: storage)
        _ = try await history.load(settings: .init(), now: now)
        let entry = ClipboardEntry(text: "kubectl get pods", capturedAt: now, sourceBundleID: "com.example.editor", sourceName: "Editor")
        _ = try await history.capture(entry, settings: .init(), now: now)
        _ = try await history.capture(ClipboardEntry(text: "kubectl get pods", capturedAt: now), settings: .init(), now: now)
        let restarted = ClipboardHistory(storage: storage)
        let result = try await restarted.load(settings: .init(), now: now)
        XCTAssertEqual(result, [entry], "dropping writes or failing to deduplicate loses/repeats clipboard entries")
    }
    func testPinsSurviveAgeCountAndOrdinaryClear() async throws {
        var settings = ClipboardSettings(); settings.maxEntries = 2; settings.retentionDays = 1
        let history = ClipboardHistory(storage: ClipboardMemoryStorage())
        _ = try await history.load(settings: settings, now: now)
        let old = ClipboardEntry(text: "keep", capturedAt: now)
        _ = try await history.capture(old, settings: settings, now: now)
        _ = try await history.setPinned(old.id, pinned: true, settings: settings, now: now)
        let tomorrow = now.addingTimeInterval(2 * 86_400)
        _ = try await history.capture(ClipboardEntry(text: "one", capturedAt: tomorrow), settings: settings, now: tomorrow)
        let result = try await history.capture(ClipboardEntry(text: "two", capturedAt: tomorrow), settings: settings, now: tomorrow)
        XCTAssertEqual(result.map(\.text), ["two", "keep"])
        let cleared = try await history.clear(includingPinned: false)
        XCTAssertEqual(cleared.map(\.text), ["keep"])
        let all = try await history.clear(includingPinned: true)
        XCTAssertTrue(all.isEmpty)
    }
    func testByteBudgetAndPinLimitRejectWithoutDestroyingProtectedEntries() async throws {
        var settings = ClipboardSettings(); settings.maxBytes = 800; settings.maxEntries = 1
        let history = ClipboardHistory(storage: ClipboardMemoryStorage())
        _ = try await history.load(settings: settings, now: now)
        let pinned = ClipboardEntry(text: String(repeating: "a", count: 300), capturedAt: now)
        _ = try await history.capture(pinned, settings: settings, now: now)
        _ = try await history.setPinned(pinned.id, pinned: true, settings: settings, now: now)
        let result = try await history.capture(ClipboardEntry(text: String(repeating: "b", count: 300), capturedAt: now), settings: settings, now: now)
        XCTAssertEqual(result.map(\.text), [pinned.text])
        settings.maxEntries = 2
        let next = ClipboardEntry(text: "small", capturedAt: now)
        _ = try await history.capture(next, settings: settings, now: now)
        _ = try await history.setPinned(next.id, pinned: true, settings: settings, now: now)
        settings.maxEntries = 1
        do { _ = try await history.load(settings: settings, now: now); XCTFail("shrinking below the pin count must not delete pins") }
        catch ClipboardHistoryError.pinnedLimit {}
    }
    func testWriteFailureKeepsLastValidHistoryAndCorruptionNeedsExplicitReset() async throws {
        let storage = ClipboardMemoryStorage()
        let history = ClipboardHistory(storage: storage)
        _ = try await history.load(settings: .init(), now: now)
        let original = ClipboardEntry(text: "original", capturedAt: now)
        _ = try await history.capture(original, settings: .init(), now: now)
        let disk = storage.data
        storage.failWrites = true
        do { _ = try await history.capture(ClipboardEntry(text: "failed", capturedAt: now), settings: .init(), now: now); XCTFail("failed writes must surface") }
        catch {}
        XCTAssertEqual(storage.data, disk)
        storage.failWrites = false
        let result = try await history.load(settings: .init(), now: now)
        XCTAssertEqual(result, [original])
        storage.data = Data("broken json".utf8)
        let corrupt = ClipboardHistory(storage: storage)
        do { _ = try await corrupt.load(settings: .init(), now: now); XCTFail("damaged history must not silently become empty") }
        catch ClipboardHistoryError.damaged {}
        XCTAssertEqual(storage.data, Data("broken json".utf8))
        _ = try await corrupt.clear(includingPinned: true)
        let reset = try await ClipboardHistory(storage: storage).load(settings: .init(), now: now)
        XCTAssertTrue(reset.isEmpty)
    }
}

extension ClipboardHistoryTests {
    func testRealStorageRestrictsPermissionsAndRejectsSymlinkReads() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let storage = ClipboardFileStorage(directory: directory)
        let history = ClipboardHistory(storage: storage)
        _ = try await history.load(settings: .init())
        _ = try await history.capture(ClipboardEntry(text: "private"), settings: .init())
        let restarted = try await ClipboardHistory(storage: storage).load(settings: .init())
        XCTAssertEqual(restarted.map(\.text), ["private"])
        let fileMode = try FileManager.default.attributesOfItem(atPath: storage.file.path)[.posixPermissions] as? NSNumber
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(fileMode?.intValue, 0o600)
        XCTAssertEqual(directoryMode?.intValue, 0o700)
        try FileManager.default.removeItem(at: storage.file)
        let other = directory.appendingPathComponent("other.json")
        try Data("[]".utf8).write(to: other)
        try FileManager.default.createSymbolicLink(at: storage.file, withDestinationURL: other)
        XCTAssertThrowsError(try storage.read())
        let replacement = Data("[1]".utf8)
        try storage.write(replacement)
        XCTAssertEqual(try Data(contentsOf: other), Data("[]".utf8), "atomic replacement must not follow the target symlink")
        XCTAssertEqual(try Data(contentsOf: storage.file), replacement)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: storage.file.path)[.type] as? FileAttributeType, .typeRegular)
    }
    func testOversizedTextDoesNotConsumeHistoryBudget() async throws {
        let history = ClipboardHistory(storage: ClipboardMemoryStorage())
        _ = try await history.load(settings: .init())
        do {
            _ = try await history.capture(ClipboardEntry(text: String(repeating: "a", count: 1_024 * 1_024 + 1)), settings: .init())
            XCTFail("individual entries must be bounded before serialization")
        } catch ClipboardHistoryError.entryTooLarge {}
        let result = try await history.load(settings: .init())
        XCTAssertTrue(result.isEmpty)
    }
}

extension ClipboardHistoryTests {
    func testEncodedByteLimitCountsUTF8AndMetadataEvenBelowEntryCountLimit() async throws {
        let storage = ClipboardMemoryStorage()
        let history = ClipboardHistory(storage: storage)
        var settings = ClipboardSettings(); settings.maxBytes = 900
        _ = try await history.load(settings: settings, now: now)
        _ = try await history.capture(ClipboardEntry(text: String(repeating: "ж", count: 200), capturedAt: now), settings: settings, now: now)
        let result = try await history.capture(ClipboardEntry(text: String(repeating: "ю", count: 200), capturedAt: now), settings: settings, now: now)
        XCTAssertEqual(result.count, 1, "UTF-8 byte limits must include the persisted metadata, not just character count")
        XCTAssertEqual(result.first?.text, String(repeating: "ю", count: 200))
        XCTAssertLessThanOrEqual(try XCTUnwrap(storage.data).count, 900)
    }
    func testUnpinAndRemoveRecoverAfterLimitsWereReducedBelowExistingPins() async throws {
        let history = ClipboardHistory(storage: ClipboardMemoryStorage())
        var settings = ClipboardSettings(); settings.maxEntries = 3
        _ = try await history.load(settings: settings, now: now)
        let first = ClipboardEntry(text: "first", capturedAt: now)
        let second = ClipboardEntry(text: "second", capturedAt: now)
        _ = try await history.capture(first, settings: settings, now: now)
        _ = try await history.setPinned(first.id, pinned: true, settings: settings, now: now)
        _ = try await history.capture(second, settings: settings, now: now)
        _ = try await history.setPinned(second.id, pinned: true, settings: settings, now: now)
        settings.maxEntries = 1
        _ = try await history.setPinned(first.id, pinned: false, settings: settings, now: now)
        let result = try await history.load(settings: settings, now: now)
        XCTAssertEqual(result.map(\.text), ["second"])
    }
}

extension ClipboardHistoryTests {
    func testStage5ContentSurvivesHistoryRestart() async throws {
        let storage = ClipboardMemoryStorage()
        let id = UUID()
        let json: [[String: Any]] = [["id": id.uuidString, "capturedAt": 800_000_000.0,
            "isPinned": true, "content": ["kind": "files", "files": ["file:///tmp/example.txt", "file:///tmp/second.txt"]]]]
        storage.data = try JSONSerialization.data(withJSONObject: json)
        let history = ClipboardHistory(storage: storage)
        do {
            let loaded = try await history.load(settings: .init(), now: now)
            XCTAssertEqual(loaded.map(\.id), [id])
            XCTAssertTrue(loaded.first?.isPinned == true)
            let restarted = try await ClipboardHistory(storage: storage).load(settings: .init(), now: now)
            XCTAssertEqual(restarted, loaded)
        } catch { XCTFail("new file content must decode without discarding history: \(error)") }
    }
    func testOldTextJSONKeepsIdentitySourceAndPins() async throws {
        let id = UUID()
        let data = try JSONSerialization.data(withJSONObject: [["id": id.uuidString, "kind": "text", "text": "legacy",
            "capturedAt": 800_000_000.0, "sourceBundleID": "com.example", "sourceName": "Example", "isPinned": true]])
        let storage = ClipboardMemoryStorage(); storage.data = data
        let loaded = try await ClipboardHistory(storage: storage).load(settings: .init(), now: now)
        XCTAssertEqual(loaded.first?.id, id); XCTAssertEqual(loaded.first?.text, "legacy")
        XCTAssertEqual(loaded.first?.sourceBundleID, "com.example"); XCTAssertEqual(loaded.first?.sourceName, "Example")
        XCTAssertTrue(loaded.first?.isPinned == true)
    }
}

extension ClipboardHistoryTests {
    func testImageSerializedBudgetEvictsUnpinnedAndKeepsProtectedImage() async throws {
        let image = try XCTUnwrap(ClipboardImageProcessor.inspect(clipboardTestImage(), type: "public.png"))
        let storage = ClipboardMemoryStorage()
        let history = ClipboardHistory(storage: storage)
        let entry = ClipboardEntry(content: .image(image), capturedAt: now)
        var settings = ClipboardSettings()
        settings.maxBytes = try JSONEncoder().encode([entry]).count + 200
        _ = try await history.load(settings: settings, now: now)
        _ = try await history.capture(entry, settings: settings, now: now)
        _ = try await history.capture(.init(content: .image(image), capturedAt: now), settings: settings, now: now)
        var entries = await history.currentEntries()
        XCTAssertEqual(entries.count, 1, "consecutive images compare bytes, not empty text")
        _ = try await history.setPinned(entry.id, pinned: true, settings: settings, now: now)
        entries = try await history.capture(.init(text: String(repeating: "x", count: 500), capturedAt: now), settings: settings, now: now)
        XCTAssertEqual(entries.map(\.id), [entry.id])
        XCTAssertLessThanOrEqual(try XCTUnwrap(storage.data).count, settings.maxBytes)
        let raw = storage.data
        storage.failWrites = true
        do { _ = try await history.clear(includingPinned: true); XCTFail("failed image transaction must surface") } catch {}
        XCTAssertEqual(storage.data, raw)
    }
}
