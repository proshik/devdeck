import AppKit
import ImageIO
import XCTest
@testable import DevDeck

func clipboardTestImage(width: Int = 1200, height: Int = 600, type: String = "public.png") throws -> Data {
    let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, type as CFString, 1, nil))
    CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
    XCTAssertTrue(CGImageDestinationFinalize(destination))
    return data as Data
}

@MainActor final class ClipboardPasteboardTests: XCTestCase {
    func testCopyBackPreservesPNGAndTIFFBytes() throws {
        let board = NSPasteboard(name: .init("stage5-image-\(UUID())")); defer { board.releaseGlobally() }
        let adapter = SystemClipboardPasteboard(pasteboard: board)
        for type in ["public.png", "public.tiff"] {
            let data = try clipboardTestImage(type: type)
            let image = try XCTUnwrap(ClipboardImageProcessor.inspect(data, type: type))
            let entry = ClipboardEntry(content: .image(image))
            XCTAssertNotNil(adapter.write(entry))
            XCTAssertEqual(board.data(forType: .init(type)), data, "image copy-back must preserve the original representation")
            XCTAssertNil(board.string(forType: .string), "image must not become an empty text clipping")
        }
    }
    func testCopyBackWritesAllFileURLsInOrder() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let urls = [directory.appendingPathComponent("one.txt"), directory.appendingPathComponent("два.txt")]
        for url in urls { try Data("test".utf8).write(to: url) }
        let board = NSPasteboard(name: .init("stage5-files-\(UUID())")); defer { board.releaseGlobally() }
        let adapter = SystemClipboardPasteboard(pasteboard: board)
        XCTAssertNotNil(adapter.write(.init(content: .files(urls))))
        let actual = (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        XCTAssertEqual(actual, urls)
    }
    func testInvalidContentLeavesClipboardIntact() throws {
        let board = NSPasteboard(name: .init("stage5-invalid-\(UUID())")); defer { board.releaseGlobally() }
        board.setString("original", forType: .string)
        let count = board.changeCount
        let adapter = SystemClipboardPasteboard(pasteboard: board)
        XCTAssertNil(adapter.write(.init(content: .files([URL(fileURLWithPath: "/missing-\(UUID())")]))))
        XCTAssertEqual(board.string(forType: .string), "original"); XCTAssertEqual(board.changeCount, count)
    }
    func testImageValidationAndThumbnailBounds() throws {
        let data = try clipboardTestImage()
        let processor = ClipboardImageProcessor()
        let image = try XCTUnwrap(processor.inspect(data, type: "public.png"))
        let thumbnail = try XCTUnwrap(processor.thumbnail(image))
        XCTAssertLessThanOrEqual(max(thumbnail.width, thumbnail.height), 512)
        XCTAssertEqual(image.width, 1200); XCTAssertEqual(image.height, 600)
        XCTAssertNil(processor.inspect(Data("broken".utf8), type: "public.png"))
        XCTAssertNil(processor.inspect(data, type: "public.tiff"))
        XCTAssertNil(processor.inspect(Data(repeating: 0, count: ClipboardImage.maxBytes + 1), type: "public.png"))
        XCTAssertFalse(ClipboardContent.image(.init(data: data, type: "public.png", width: 99_999_999, height: 1)).isValid)
    }
}

extension ClipboardPasteboardTests {
    func testCollectorPersistsMixedContentFiltersAndOwnCopyDoesNotDuplicate() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("sample.txt"); try Data("sample".utf8).write(to: file)
        let board = NSPasteboard(name: .init("stage5-collection-\(UUID())")); defer { board.releaseGlobally() }
        let adapter = SystemClipboardPasteboard(pasteboard: board)
        let storage = ClipboardFileStorage(directory: directory.appendingPathComponent("history"))
        let model = ClipboardModel(history: ClipboardHistory(storage: storage), pasteboard: adapter)
        var settings = ClipboardSettings(); settings.enabled = true
        await model.synchronize(settings)
        let image = try XCTUnwrap(ClipboardImageProcessor.inspect(clipboardTestImage(), type: "public.png"))
        for content: ClipboardContent in [.text("find me"), .image(image), .files([file])] {
            XCTAssertNotNil(adapter.write(.init(content: content)))
            await model.poll()
        }
        XCTAssertEqual(model.entries.map(\.kind), [.files, .image, .text])
        XCTAssertEqual(model.search("sample", kind: .files).count, 1)
        XCTAssertEqual(model.search("find", kind: .image).count, 0)
        XCTAssertEqual(model.search("", kind: .image).first?.content, .image(image))
        let imageEntry = try XCTUnwrap(model.entries.first(where: { $0.kind == .image }))
        XCTAssertTrue(model.copy(imageEntry)); await model.poll()
        XCTAssertEqual(model.entries.count, 3)
        let restored = try await ClipboardHistory(storage: storage).load(settings: settings)
        XCTAssertEqual(restored, model.entries)
        await model.setPinned(imageEntry)
        await model.clear(includingPinned: false)
        XCTAssertEqual(model.entries.map(\.content), [.image(image)])
        // File disappearance must fail copy without touching the existing image in pasteboard.
        let before = board.changeCount
        try FileManager.default.removeItem(at: file)
        XCTAssertFalse(model.copy(.init(content: .files([file]))))
        XCTAssertEqual(board.changeCount, before); XCTAssertNotNil(model.errorMessage)
    }
    func testImageTakesPriorityOverTextButFilesTakePriorityOverImage() throws {
        let board = NSPasteboard(name: .init("stage5-priority-\(UUID())")); defer { board.releaseGlobally() }
        let adapter = SystemClipboardPasteboard(pasteboard: board)
        let image = try clipboardTestImage(width: 1, height: 1)
        let item = NSPasteboardItem(); item.setData(image, forType: .png); item.setString("image name", forType: .string)
        board.writeObjects([item])
        let snapshot = try XCTUnwrap(adapter.snapshot(excludedBundleIDs: []))
        XCTAssertNil(snapshot.text); XCTAssertEqual(snapshot.imageData, image)
        let fileItem = NSPasteboardItem(); fileItem.setData(image, forType: .png)
        fileItem.setString("file:///tmp/example.txt", forType: .fileURL)
        board.clearContents(); board.writeObjects([fileItem])
        let files = try XCTUnwrap(adapter.snapshot(excludedBundleIDs: []))
        XCTAssertEqual(files.fileURLs, [URL(fileURLWithPath: "/tmp/example.txt")]); XCTAssertNil(files.imageData)
        let concealed = NSPasteboardItem(); concealed.setString("file:///tmp/example.txt", forType: .fileURL)
        concealed.setData(Data(), forType: .init("org.nspasteboard.ConcealedType"))
        board.clearContents(); board.writeObjects([concealed])
        XCTAssertNil(adapter.snapshot(excludedBundleIDs: []))
    }
    func testSettingsRetainPasteOptInAndLegacyDefaults() throws {
        let old = try JSONDecoder().decode(ClipboardSettings.self, from: Data("{}".utf8))
        XCTAssertFalse(old.pasteEnabled)
        var enabled = old; enabled.pasteEnabled = true
        XCTAssertEqual(try JSONDecoder().decode(ClipboardSettings.self, from: JSONEncoder().encode(enabled)), enabled)
    }
}

extension ClipboardPasteboardTests {
    func testDamagedPixelDataAndOversizedHeaderAreRejectedBeforeCapture() throws {
        let original = try clipboardTestImage(width: 1, height: 1)
        func crc(_ bytes: Data) -> UInt32 {
            var value: UInt32 = 0xffff_ffff
            for byte in bytes {
                value ^= UInt32(byte)
                for _ in 0..<8 { value = (value >> 1) ^ (value & 1 == 1 ? 0xedb8_8320 : 0) }
            }
            return value ^ 0xffff_ffff
        }
        func write(_ value: UInt32, to data: inout Data, at index: Int) {
            for offset in 0..<4 { data[index + offset] = UInt8(truncatingIfNeeded: value >> ((3 - offset) * 8)) }
        }
        let huge = try autoreleasepool { try clipboardTestImage(width: 8000, height: 6000) }
        let source = try XCTUnwrap(CGImageSourceCreateWithData(huge as CFData, nil))
        let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        XCTAssertEqual((properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue, 8000)
        XCTAssertNil(ClipboardImageProcessor.inspect(huge, type: "public.png"))
        var damaged = original
        var offset = 8
        var changed = false
        while offset + 12 <= damaged.count {
            let length = damaged[offset..<offset+4].reduce(0) { ($0 << 8) | Int($1) }
            guard offset + 12 + length <= damaged.count else { break }
            if String(data: damaged.subdata(in: offset+4..<offset+8), encoding: .ascii) == "IDAT", length > 0 {
                damaged[offset+8] = 0 // invalid zlib header; container checksum remains valid
                write(crc(damaged.subdata(in: offset+4..<offset+8+length)), to: &damaged, at: offset+8+length)
                changed = true; break
            }
            offset += length + 12
        }
        XCTAssertTrue(changed)
        XCTAssertNil(ClipboardImageProcessor.inspect(damaged, type: "public.png"), "valid dimensions alone must not admit damaged pixels")
    }
}
