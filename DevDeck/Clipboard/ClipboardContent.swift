import Foundation

struct ClipboardImage: Codable, Equatable, Sendable {
    let data: Data
    let type: String
    let width: Int
    let height: Int
    static let maxBytes = 10 * 1_024 * 1_024
    static let maxPixels = 40_000_000
}

enum ClipboardContent: Equatable, Sendable, Codable {
    enum Kind: String, Codable, CaseIterable, Sendable { case text, image, files }
    case text(String)
    case image(ClipboardImage)
    case files([URL])
    var kind: Kind {
        switch self { case .text: .text; case .image: .image; case .files: .files }
    }
    var searchText: String {
        switch self {
        case .text(let value): value
        case .image: ""
        case .files(let urls): urls.map(\.lastPathComponent).joined(separator: "\n")
        }
    }
    var isValid: Bool {
        switch self {
        case .text(let value): !value.isEmpty && value.utf8.count <= ClipboardSettings.maxEntryBytes
        case .image(let image): ClipboardImageProcessor.inspect(image.data, type: image.type) == image
        case .files(let urls):
            !urls.isEmpty && urls.count <= 100 && urls.allSatisfy { $0.isFileURL && !$0.path.isEmpty && ($0.host == nil || $0.host == "" || $0.host == "localhost") }
                && urls.reduce(0, { $0 + $1.absoluteString.utf8.count }) <= ClipboardSettings.maxEntryBytes
        }
    }
    private enum CodingKeys: String, CodingKey { case kind, text, image, files }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(Kind.self, forKey: .kind) {
        case .text: self = .text(try c.decode(String.self, forKey: .text))
        case .image: self = .image(try c.decode(ClipboardImage.self, forKey: .image))
        case .files: self = .files(try c.decode([URL].self, forKey: .files))
        }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .text(let value): try c.encode(value, forKey: .text)
        case .image(let value): try c.encode(value, forKey: .image)
        case .files(let value): try c.encode(value, forKey: .files)
        }
    }
}

struct ClipboardEntry: Codable, Equatable, Identifiable, Sendable {
    typealias Kind = ClipboardContent.Kind
    let id: UUID
    let content: ClipboardContent
    let capturedAt: Date
    let sourceBundleID: String?
    let sourceName: String?
    var isPinned: Bool
    var kind: Kind { content.kind }
    // Text callers retain their original contract during format migration.
    var text: String { if case .text(let value) = content { value } else { "" } }
    var searchText: String { content.searchText }
    var displayTitle: String {
        switch content {
        case .text(let value): String(value.prefix(240)).replacingOccurrences(of: "\n", with: " ")
        case .image(let value): L10n.clipboardImage + " · \(value.width) × \(value.height)"
        case .files(let urls): urls.map(\.lastPathComponent).joined(separator: ", ")
        }
    }
    init(text: String, capturedAt: Date = Date(), sourceBundleID: String? = nil, sourceName: String? = nil) {
        self.init(content: .text(text), capturedAt: capturedAt, sourceBundleID: sourceBundleID, sourceName: sourceName)
    }
    init(content: ClipboardContent, capturedAt: Date = Date(), sourceBundleID: String? = nil, sourceName: String? = nil) {
        id = UUID(); self.content = content; self.capturedAt = capturedAt
        self.sourceBundleID = sourceBundleID; self.sourceName = sourceName; isPinned = false
    }
    private enum CodingKeys: String, CodingKey { case id, content, kind, text, capturedAt, sourceBundleID, sourceName, isPinned }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        if let value = try c.decodeIfPresent(ClipboardContent.self, forKey: .content) { content = value }
        else {
            guard try c.decode(Kind.self, forKey: .kind) == .text else {
                throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unsupported legacy content")
            }
            content = .text(try c.decode(String.self, forKey: .text))
        }
        capturedAt = try c.decode(Date.self, forKey: .capturedAt)
        sourceBundleID = try c.decodeIfPresent(String.self, forKey: .sourceBundleID)
        sourceName = try c.decodeIfPresent(String.self, forKey: .sourceName)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(content, forKey: .content)
        try c.encode(capturedAt, forKey: .capturedAt); try c.encode(isPinned, forKey: .isPinned)
        try c.encodeIfPresent(sourceBundleID, forKey: .sourceBundleID); try c.encodeIfPresent(sourceName, forKey: .sourceName)
    }
}
