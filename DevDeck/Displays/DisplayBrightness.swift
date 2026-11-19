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
    /// Per-display (UUID) luminance range for the approximate nits estimate of DDC displays.
    var luminance: [String: BrightnessLuminanceRange] = [:]
    init() {}
    enum CodingKeys: CodingKey { case keyboardEnabled, linkSliders, linkKeys, methods, luminance }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        keyboardEnabled = try c.decodeIfPresent(Bool.self, forKey: .keyboardEnabled) ?? false
        linkSliders = try c.decodeIfPresent(Bool.self, forKey: .linkSliders) ?? false
        linkKeys = try c.decodeIfPresent(Bool.self, forKey: .linkKeys) ?? false
        methods = try c.decodeIfPresent([String: BrightnessMethod].self, forKey: .methods) ?? [:]
        luminance = try c.decodeIfPresent([String: BrightnessLuminanceRange].self, forKey: .luminance) ?? [:]
    }
}

/// Datasheet-style luminance endpoints in cd/m². A missing field falls back to the
/// built-in default for the monitor model, if there is one.
struct BrightnessLuminanceRange: Codable, Equatable, Sendable {
    var minimum: Double?
    var maximum: Double?
    init(minimum: Double? = nil, maximum: Double? = nil) { self.minimum = minimum; self.maximum = maximum }
}

struct BrightnessDisplay: Identifiable, Equatable, Sendable {
    let id: String
    let displayID: CGDirectDisplayID
    let name: String
    let bounds: CGRect
    let builtIn: Bool
    var value: Double?
    var method: BrightnessMethod = .hardware
    /// VCP 0x10 maximum reported by the monitor; set only for the external DDC route.
    var hardwareMaximum: UInt16? = nil
    /// EDID manufacturer and product code (CGDisplayVendorNumber / CGDisplayModelNumber).
    var edidVendor: UInt32 = 0
    var edidProduct: UInt32 = 0
    /// Panel luminance macOS reports for the built-in display (cd/m²); nil when unavailable.
    var reportedNits: Double? = nil
}

enum BrightnessFailure: Error { case unavailable, write, readback, unconfirmed(actual: Double) }

protocol DisplayBrightnessProvider: Sendable {
    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay]
    /// Returns actual readback. Check task cancellation immediately before each physical
    /// write (also after any preceding suspension/read), so invalidated work cannot commit.
    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double
    /// Current macOS-reported panel luminance of a built-in display, read after any write.
    func reportedNits(_ display: BrightnessDisplay) async -> Double?
    func reset() async
}

extension DisplayBrightnessProvider {
    func reportedNits(_ display: BrightnessDisplay) async -> Double? { nil }
}

enum BrightnessRouting {
    static func target(at point: CGPoint, displays: [BrightnessDisplay]) -> BrightnessDisplay? {
        displays.first { $0.bounds.contains(point) && $0.value != nil }
    }
}

/// Control scale for external DDC only, not measured luminance. Logical 0 is the black
/// image cover (no hardware write); the positive range p ∈ [1%, 100%] spans every hardware
/// level raw0…rawMax: raw = round(rawMax·((p−1)/99)²), so raw0 (darkest visible) is 1%.
enum BrightnessDDCScale {
    /// Logical value of hardware raw0, the lowest positive level.
    static let minimumPositive = 0.01
    static func hardwareFraction(_ logical: Double) -> Double? {
        guard logical.isFinite else { return nil }
        let positive = max(0, min(1, logical) - minimumPositive) / (1 - minimumPositive)
        return positive * positive
    }
    static func logicalFraction(_ hardware: Double) -> Double? {
        guard hardware.isFinite else { return nil }
        return minimumPositive + (1 - minimumPositive) * min(1, max(0, hardware)).squareRoot()
    }
    static func logical(raw: UInt16, maximum: UInt16) -> Double? {
        guard maximum > 0, raw <= maximum else { return nil }
        return logicalFraction(Double(raw) / Double(maximum))
    }
    static func rawTarget(_ logical: Double, maximum: UInt16) throws -> UInt16 {
        guard maximum > 0, let hardware = hardwareFraction(logical) else { throw BrightnessFailure.write }
        return UInt16((hardware * Double(maximum)).rounded())
    }
    /// Next key request from `base`: the plain logical step, unless it would land on the same
    /// hardware level, in which case the neighbouring raw level in the step's direction.
    /// Up from black always starts at raw0; only raw0 steps down to black.
    static func keyTarget(from base: Double, step: Double, maximum: UInt16) -> Double {
        let candidate = min(1, max(0, base + step))
        guard maximum > 0, base.isFinite, step.isFinite, step != 0 else { return candidate }
        guard base > 0 else { return step > 0 ? minimumPositive : 0 }
        guard let from = try? rawTarget(base, maximum: maximum) else { return candidate }
        if candidate == 0 { return from > 0 ? minimumPositive : 0 }
        guard let to = try? rawTarget(candidate, maximum: maximum) else { return candidate }
        if step > 0, to <= from {
            return from < maximum ? logical(raw: from + 1, maximum: maximum) ?? candidate : candidate
        }
        if step < 0, to >= from {
            return from > 0 ? logical(raw: from - 1, maximum: maximum) ?? candidate : 0
        }
        return candidate
    }
}

/// Nits next to the percentage. Built-in: the luminance macOS reports for the panel.
/// External DDC: linear in the confirmed raw level between datasheet endpoints.
/// Never invented: without a reported value or a known/user range there is no value.
enum BrightnessLuminance {
    static func value(_ display: BrightnessDisplay, settings: DisplayBrightnessSettings) -> Double? {
        guard display.builtIn else { return estimate(display, settings: settings) }
        guard display.method == .hardware, let value = display.value, value > 0,
              let nits = display.reportedNits, nits.isFinite, nits >= 0 else { return nil }
        return nits
    }
    /// IOMFBBrightnessLevel of the backlit (BLNitsCap) framebuffer, 16.16 fixed-point cd/m².
    /// External pipes publish a 1.0 placeholder without a cap and are rejected.
    static func panelNits(_ properties: [String: Any]) -> Double? {
        guard properties["BLNitsCap"] is NSNumber,
              let level = properties["IOMFBBrightnessLevel"] as? NSNumber else { return nil }
        let nits = level.doubleValue / 65536
        return nits.isFinite && nits >= 0 ? nits : nil
    }

    /// Defaults keyed by EDID manufacturer and product code, not by the (localizable,
    /// de-duplicated) screen name.
    static let defaults: [UInt64: BrightnessLuminanceRange] = [
        // DELL U2720Q: 350 cd/m² datasheet maximum, 29 cd/m² RTINGS minimum measurement.
        key(vendor: 0x10AC, product: 0x41B5): BrightnessLuminanceRange(minimum: 29, maximum: 350),
    ]
    static func key(vendor: UInt32, product: UInt32) -> UInt64 { UInt64(vendor) << 32 | UInt64(product) }

    static func range(for display: BrightnessDisplay, settings: DisplayBrightnessSettings) -> (minimum: Double, maximum: Double)? {
        let fallback = defaults[key(vendor: display.edidVendor, product: display.edidProduct)]
        let user = settings.luminance[display.id]
        guard let minimum = user?.minimum ?? fallback?.minimum, let maximum = user?.maximum ?? fallback?.maximum,
              minimum.isFinite, maximum.isFinite, minimum >= 0, maximum > minimum else { return nil }
        return (minimum, maximum)
    }
    static func estimate(_ display: BrightnessDisplay, settings: DisplayBrightnessSettings) -> Double? {
        guard !display.builtIn, display.method == .hardware, let maximum = display.hardwareMaximum,
              let value = display.value, value > 0,
              let raw = try? BrightnessDDCScale.rawTarget(value, maximum: maximum),
              let range = range(for: display, settings: settings) else { return nil }
        return range.minimum + (range.maximum - range.minimum) * Double(raw) / Double(maximum)
    }
}

enum BrightnessLevelText {
    static func text(value: Double, nits: Double?) -> String {
        let percent = value.formatted(.percent.precision(.fractionLength(0)))
        guard let nits, nits.isFinite else { return percent }
        return percent + " • " + L10n.brightnessNits(Int(nits.rounded()))
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
