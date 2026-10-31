import Foundation
import CoreGraphics

enum BrightnessMethod: String, Codable, CaseIterable, Sendable {
    case hardware, software
    var title: String { self == .hardware ? L10n.brightnessHardware : L10n.brightnessSoftware }
}

struct DisplayBrightnessSettings: Codable, Equatable, Sendable {
    var keyboardEnabled = false
    var linkSliders = false
    var linkKeys = false
    var methods: [String: BrightnessMethod] = [:]
    init() {}
    enum CodingKeys: CodingKey { case keyboardEnabled, linkSliders, linkKeys, methods }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyboardEnabled = try c.decodeIfPresent(Bool.self, forKey: .keyboardEnabled) ?? false
        linkSliders = try c.decodeIfPresent(Bool.self, forKey: .linkSliders) ?? false
        linkKeys = try c.decodeIfPresent(Bool.self, forKey: .linkKeys) ?? false
        methods = try c.decodeIfPresent([String: BrightnessMethod].self, forKey: .methods) ?? [:]
    }
}

struct BrightnessDisplay: Identifiable, Equatable, Sendable {
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    let bounds: CGRect
    let builtIn: Bool
    var value: Double?
    var method: BrightnessMethod = .hardware
}

enum BrightnessFailure: Error { case unavailable, write, readback }

protocol DisplayBrightnessProvider: Sendable {
    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay]
    /// Returns actual readback. Check task cancellation immediately before each physical
    /// write (also after any preceding suspension/read), so invalidated work cannot commit.
    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double
    func reset() async
}

enum BrightnessRouting {
    static func target(at point: CGPoint, displays: [BrightnessDisplay]) -> BrightnessDisplay? {
        displays.first { $0.bounds.contains(point) && $0.value != nil }
    }
}

/// DDC/CI VCP luminance (0x10). The IOAV transport supplies the source address separately.
enum BrightnessDDC {
    static let read: [UInt8] = [0x82, 0x01, 0x10, 0xfd]
    static func write(_ value: UInt16) -> [UInt8] {
        let bytes: [UInt8] = [0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xff)]
        return bytes + [bytes.reduce(0x6e ^ 0x51, ^)]
    }
    static func decode(_ bytes: [UInt8]) -> (current: UInt16, maximum: UInt16)? {
        guard bytes.count == 11, bytes[0] == 0x6e, bytes[1] == 0x88,
              bytes[2] == 0x02, bytes[3] == 0, bytes[4] == 0x10,
              bytes.reduce(0x50, ^) == 0 else { return nil }
        let maximum = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        let current = UInt16(bytes[8]) << 8 | UInt16(bytes[9])
        guard maximum > 0, current <= maximum else { return nil }
        return (current, maximum)
    }
}
