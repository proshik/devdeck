import Foundation

struct ClipboardSettings: Codable, Equatable, Sendable {
    var enabled = false
    var paused = false
    var pasteEnabled = false
    var maxEntries = 500
    var retentionDays = 30
    var maxBytes = 20 * 1_024 * 1_024
    var excludedBundleIDs: [String] = []
    static let maxEntryBytes = 1_024 * 1_024
    var pinLimit: Int { min(100, maxEntries) }
    init() {}
    enum CodingKeys: String, CodingKey { case enabled, paused, pasteEnabled, maxEntries, retentionDays, maxBytes, excludedBundleIDs }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? false
        pasteEnabled = try c.decodeIfPresent(Bool.self, forKey: .pasteEnabled) ?? false
        maxEntries = min(10_000, max(1, try c.decodeIfPresent(Int.self, forKey: .maxEntries) ?? 500))
        retentionDays = min(365, max(1, try c.decodeIfPresent(Int.self, forKey: .retentionDays) ?? 30))
        maxBytes = min(100 * 1_024 * 1_024, max(1_024, try c.decodeIfPresent(Int.self, forKey: .maxBytes) ?? 20 * 1_024 * 1_024))
        excludedBundleIDs = try c.decodeIfPresent([String].self, forKey: .excludedBundleIDs) ?? []
    }
}

protocol ClipboardHistoryStorage: Sendable {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

enum ClipboardHistoryError: Error { case damaged, writeFailed, pinnedLimit, entryTooLarge }

/// All transactions, including disk writes, execute serially away from the UI actor.
/// A failed write never publishes a candidate over the last valid state.
actor ClipboardHistory {
    private let storage: any ClipboardHistoryStorage
    private var entries: [ClipboardEntry] = []
    private var loaded = false
    init(storage: any ClipboardHistoryStorage) { self.storage = storage }
    func currentEntries() -> [ClipboardEntry] { entries }
    func load(settings: ClipboardSettings, now: Date = Date()) throws -> [ClipboardEntry] {
        if !loaded {
            if let data = try storage.read() {
                guard data.count <= 101 * 1_024 * 1_024,
                      let decoded = try? JSONDecoder().decode([ClipboardEntry].self, from: data),
                      decoded.count <= 10_000, Set(decoded.map(\.id)).count == decoded.count,
                      decoded.allSatisfy({ $0.content.isValid }) else {
                    throw ClipboardHistoryError.damaged
                }
                entries = decoded.sorted { $0.capturedAt > $1.capturedAt }
            }
            loaded = true
        }
        return try commit(limited(entries, settings: settings, now: now))
    }
    func capture(_ entry: ClipboardEntry, settings: ClipboardSettings, now: Date = Date()) throws -> [ClipboardEntry] {
        _ = try load(settings: settings, now: now)
        guard entry.content.isValid else { throw ClipboardHistoryError.entryTooLarge }
        guard entries.first?.content != entry.content else { return entries }
        return try commit(limited([entry] + entries, settings: settings, now: now))
    }
    func setPinned(_ id: UUID, pinned: Bool, settings: ClipboardSettings, now: Date = Date()) throws -> [ClipboardEntry] {
        if !loaded { _ = try load(settings: settings, now: now) }
        var candidate = entries
        guard let index = candidate.firstIndex(where: { $0.id == id }) else { return entries }
        candidate[index].isPinned = pinned
        // Unpinning must remain possible after the user lowers the budget below existing pins.
        return try commit(pinned ? limited(candidate, settings: settings, now: now) : candidate)
    }
    func remove(_ id: UUID) throws -> [ClipboardEntry] {
        guard loaded else { throw ClipboardHistoryError.damaged }
        return try commit(entries.filter { $0.id != id })
    }
    func clear(includingPinned: Bool) throws -> [ClipboardEntry] {
        guard loaded || includingPinned else { throw ClipboardHistoryError.damaged }
        let result = try commit(includingPinned ? [] : entries.filter(\.isPinned), force: !loaded)
        loaded = true
        return result
    }

    private func limited(_ input: [ClipboardEntry], settings: ClipboardSettings, now: Date) throws -> [ClipboardEntry] {
        let cutoff = now.addingTimeInterval(-Double(settings.retentionDays) * 86_400)
        let candidate = input.filter { $0.isPinned || $0.capturedAt >= cutoff }
        let pins = candidate.filter(\.isPinned)
        guard pins.count <= settings.pinLimit, try encoded(pins).count <= settings.maxBytes else {
            throw ClipboardHistoryError.pinnedLimit
        }
        // JSON array bytes = entry bytes + brackets + commas. Serialize each entry once,
        // so reducing a full history's limits does not repeatedly encode the entire file.
        let sizes = try candidate.map { try JSONEncoder().encode($0).count }
        var bytes = 2 + sizes.reduce(0, +) + max(0, candidate.count - 1)
        var count = candidate.count
        var removed: Set<Int> = []
        for index in candidate.indices.reversed() where !candidate[index].isPinned {
            if count <= settings.maxEntries && bytes <= settings.maxBytes { break }
            bytes -= sizes[index] + (count > 1 ? 1 : 0)
            count -= 1
            removed.insert(index)
        }
        return candidate.enumerated().filter { !removed.contains($0.offset) }.map(\.element)
    }
    private func encoded(_ entries: [ClipboardEntry]) throws -> Data { try JSONEncoder().encode(entries) }
    private func commit(_ candidate: [ClipboardEntry], force: Bool = false) throws -> [ClipboardEntry] {
        guard force || candidate != entries else { return entries }
        do { try storage.write(encoded(candidate)) }
        catch { throw ClipboardHistoryError.writeFailed }
        entries = candidate
        return entries
    }
}
