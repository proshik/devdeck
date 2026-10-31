import Foundation
import ImageIO
import CoreGraphics

protocol ClipboardImageProcessing: Sendable {
    func inspect(_ data: Data, type: String) -> ClipboardImage?
    func thumbnail(_ image: ClipboardImage) -> CGImage?
}

struct ClipboardImageProcessor: ClipboardImageProcessing {
    private static func decode(_ data: Data, type: String) -> (ClipboardImage, CGImage)? {
        guard !data.isEmpty, data.count <= ClipboardImage.maxBytes,
              ["public.png", "public.tiff"].contains(type),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetType(source) as String? == type,
              CGImageSourceGetStatus(source) == .statusComplete,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let h = properties[kCGImagePropertyPixelHeight] as? NSNumber else { return nil }
        let width = w.intValue, height = h.intValue
        guard width > 0, height > 0, width <= ClipboardImage.maxPixels,
              height <= ClipboardImage.maxPixels / width else { return nil }
        if type == "public.png", !ClipboardPNGValidation.valid(data, width: width, height: height) { return nil }
        // A valid container/header is not enough: damaged compressed pixels must be
        // rejected too. Validate by decoding only a capped thumbnail, never a full image.
        guard let preview = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 512,
            kCGImageSourceShouldCacheImmediately: true
        ] as CFDictionary), CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete else { return nil }
        return (.init(data: data, type: type, width: width, height: height), preview)
    }
    static func inspect(_ data: Data, type: String) -> ClipboardImage? { decode(data, type: type)?.0 }
    func inspect(_ data: Data, type: String) -> ClipboardImage? { Self.inspect(data, type: type) }
    func thumbnail(_ image: ClipboardImage) -> CGImage? {
        guard let result = Self.decode(image.data, type: image.type), result.0 == image else { return nil }
        return result.1
    }
}

actor ClipboardPreviewCache {
    static let shared = ClipboardPreviewCache()
    private var cache: [UUID: CGImage] = [:]
    private var order: [UUID] = []
    private let processor: any ClipboardImageProcessing
    init(processor: any ClipboardImageProcessing = ClipboardImageProcessor()) { self.processor = processor }
    func preview(id: UUID, image: ClipboardImage) -> CGImage? {
        if let value = cache[id] { return value }
        guard let value = processor.thumbnail(image) else { return nil }
        cache[id] = value; order.append(id)
        while order.count > 24 || cache.values.reduce(0, { $0 + $1.bytesPerRow * $1.height }) > 16 * 1_024 * 1_024 {
            cache.removeValue(forKey: order.removeFirst())
        }
        return value
    }
    func retainOnly(_ ids: Set<UUID>) {
        cache = cache.filter { ids.contains($0.key) }; order.removeAll { !ids.contains($0) }
    }
}
