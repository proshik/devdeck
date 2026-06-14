import XCTest
@testable import DevDeck

final class DiagnosticLogTests: XCTestCase {

    private func tempLogURL() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("devdeck.log")
    }

    func testDefaultURLRoutesToTempUnderXCTest() {
        // Under tests, defaultURL must not point to the real application log
        // (Application Support/DevDeck), so tests don't pollute it.
        let path = DiagnosticLog.defaultURL.path
        XCTAssertTrue(path.hasPrefix(FileManager.default.temporaryDirectory.path), path)
        XCTAssertFalse(path.contains("Application Support/DevDeck"), path)
    }

    func testLogAppendsTimestampedLeveledLines() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let log = DiagnosticLog(fileURL: url)
        log.log("first event")
        log.log("something went wrong", level: .error)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[INFO] first event"), text)
        XCTAssertTrue(text.contains("[ERROR] something went wrong"), text)
        XCTAssertEqual(text.split(separator: "\n").count, 2)
    }

    func testRotatesWithinSessionWhenLogGrowsOverCap() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let log = DiagnosticLog(fileURL: url, maxBytes: 500)
        for i in 0..<60 { log.log("line number \(i) with text to pad out the volume") }   // well over 500 bytes

        let backup = url.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "in-session rotation created a backup")
        let mainSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        XCTAssertLessThanOrEqual(mainSize, 600, "after rotation the main log does not exceed the limit (+1 line)")
    }

    func testRotatesWhenOverCapOnInit() throws {
        let url = tempLogURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        try String(repeating: "x", count: 2000).write(to: url, atomically: true, encoding: .utf8)
        _ = DiagnosticLog(fileURL: url, maxBytes: 1000)   // limit exceeded → rotation

        let backup = url.appendingPathExtension("1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backup.path), "backup .1 was created")
        let mainSize = (try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
        XCTAssertEqual(mainSize, 0, "main log was started fresh")
    }
}
