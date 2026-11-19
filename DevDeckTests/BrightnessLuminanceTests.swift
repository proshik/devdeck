import XCTest
@testable import DevDeck

final class BrightnessLuminanceTests: XCTestCase {
    private func external(vendor: UInt32 = 0x10AC, product: UInt32 = 0x41B5, raw: UInt16?, maximum: UInt16 = 100,
                          method: BrightnessMethod = .hardware, id: String = "dell") -> BrightnessDisplay {
        BrightnessDisplay(id: id, displayID: 2, name: "DELL U2720Q", bounds: .zero, builtIn: false,
                          value: raw.map { BrightnessDDCScale.logical(raw: $0, maximum: maximum)! },
                          method: method, hardwareMaximum: method == .hardware ? maximum : nil,
                          edidVendor: vendor, edidProduct: product)
    }

    func testDellDefaultsComeFromEDIDVendorAndProductNotTheName() throws {
        let settings = DisplayBrightnessSettings()
        XCTAssertEqual(try XCTUnwrap(BrightnessLuminance.estimate(external(raw: 0), settings: settings)), 29, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(BrightnessLuminance.estimate(external(raw: 24), settings: settings)), 29 + 321 * 0.24, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(BrightnessLuminance.estimate(external(raw: 100), settings: settings)), 350, accuracy: 1e-9)
        XCTAssertNil(BrightnessLuminance.estimate(external(product: 0x41B6, raw: 24), settings: settings),
                     "same name, other EDID product → no invented nits")
        XCTAssertNil(BrightnessLuminance.estimate(external(vendor: 0x4C2D, raw: 24), settings: settings))
    }

    func testUserRangeOverridesDefaultsPerDisplayAndEnablesUnknownMonitors() throws {
        var settings = DisplayBrightnessSettings()
        settings.luminance["dell"] = BrightnessLuminanceRange(minimum: nil, maximum: 400)
        XCTAssertEqual(try XCTUnwrap(BrightnessLuminance.estimate(external(raw: 100), settings: settings)), 400, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(BrightnessLuminance.estimate(external(raw: 0), settings: settings)), 29, accuracy: 1e-9)
        let unknown = external(vendor: 0x1234, product: 1, raw: 51, maximum: 255, id: "other")
        XCTAssertNil(BrightnessLuminance.estimate(unknown, settings: settings))
        settings.luminance["other"] = BrightnessLuminanceRange(minimum: 0, maximum: 250)
        XCTAssertEqual(try XCTUnwrap(BrightnessLuminance.estimate(unknown, settings: settings)), 50, accuracy: 1e-9,
                       "linear in raw against the reported rawMax 255")
        settings.luminance["other"] = BrightnessLuminanceRange(minimum: nil, maximum: 250)
        XCTAssertNil(BrightnessLuminance.estimate(unknown, settings: settings), "half a range is not enough without defaults")
    }

    func testInvalidRangesBlackSoftwareAndBuiltInShowOnlyPercent() {
        var settings = DisplayBrightnessSettings()
        for range in [BrightnessLuminanceRange(minimum: 300, maximum: 300), .init(minimum: 400, maximum: 300),
                      .init(minimum: -1, maximum: 300), .init(minimum: 0, maximum: .nan), .init(minimum: 0, maximum: .infinity)] {
            settings.luminance["dell"] = range
            XCTAssertNil(BrightnessLuminance.estimate(external(raw: 24), settings: settings), "\(range)")
        }
        settings = DisplayBrightnessSettings()
        XCTAssertNil(BrightnessLuminance.estimate(external(raw: 24, method: .software), settings: settings))
        var black = external(raw: 24); black.value = 0
        XCTAssertNil(BrightnessLuminance.estimate(black, settings: settings), "0% is the black cover, not a luminance")
        let builtIn = BrightnessDisplay(id: "mac", displayID: 1, name: "Color LCD", bounds: .zero, builtIn: true,
                                        value: 0.5, edidVendor: 0x10AC, edidProduct: 0x41B5)
        settings.luminance["mac"] = BrightnessLuminanceRange(minimum: 1, maximum: 600)
        XCTAssertNil(BrightnessLuminance.estimate(builtIn, settings: settings),
                     "built-in has no live macOS nits on this hardware and is never estimated")
    }

    func testBuiltInShowsTheLuminanceMacOSReportsForThePanel() {
        let settings = DisplayBrightnessSettings()
        var builtIn = BrightnessDisplay(id: "mac", displayID: 1, name: "Built-in", bounds: .zero, builtIn: true,
                                        value: 0.75, reportedNits: 224.75)
        XCTAssertEqual(BrightnessLuminance.value(builtIn, settings: settings), 224.75)
        builtIn.value = 0
        XCTAssertNil(BrightnessLuminance.value(builtIn, settings: settings), "0% is the black cover, not the backlight")
        builtIn.value = 0.75; builtIn.method = .software
        XCTAssertNil(BrightnessLuminance.value(builtIn, settings: settings), "software dimming is not the panel luminance")
        builtIn.method = .hardware
        for reported in [nil, -1, .nan, .infinity] as [Double?] {
            builtIn.reportedNits = reported
            XCTAssertNil(BrightnessLuminance.value(builtIn, settings: settings), "\(String(describing: reported))")
        }
        XCTAssertEqual(try XCTUnwrap(BrightnessLuminance.value(external(raw: 24), settings: settings)), 29 + 321 * 0.24,
                       accuracy: 1e-9, "external displays keep the datasheet estimate")
    }

    func testBuiltInPanelLuminanceIsReadFromTheBacklitFramebufferOnly() {
        let level = NSNumber(value: Int64(224.75 * 65536)), cap = NSNumber(value: 26227508)
        XCTAssertEqual(BrightnessLuminance.panelNits(["IOMFBBrightnessLevel": level, "BLNitsCap": cap]), 224.75)
        XCTAssertEqual(BrightnessLuminance.panelNits(["IOMFBBrightnessLevel": NSNumber(value: 0), "BLNitsCap": cap]), 0)
        XCTAssertNil(BrightnessLuminance.panelNits(["IOMFBBrightnessLevel": NSNumber(value: 65536)]),
                     "external pipes publish a 1.0 placeholder without a backlight cap")
        XCTAssertNil(BrightnessLuminance.panelNits(["BLNitsCap": cap]))
        XCTAssertNil(BrightnessLuminance.panelNits(["IOMFBBrightnessLevel": NSNumber(value: -65536), "BLNitsCap": cap]))
        XCTAssertNil(BrightnessLuminance.panelNits(["IOMFBBrightnessLevel": "400", "BLNitsCap": cap]))
    }

    @MainActor func testLevelTextShowsApproximateNitsOnlyWhenKnown() {
        let language = LocalizationManager.shared.language
        defer { LocalizationManager.shared.language = language }
        // The percentage follows the system number locale, like every other percent in the app.
        let percent = 0.52.formatted(.percent.precision(.fractionLength(0)))
        LocalizationManager.shared.language = .en
        XCTAssertEqual(BrightnessLevelText.text(value: 0.52, nits: 94.4), percent + " • ≈94 nits")
        XCTAssertEqual(BrightnessLevelText.text(value: 0.52, nits: nil), percent)
        LocalizationManager.shared.language = .ru
        XCTAssertEqual(BrightnessLevelText.text(value: 0.52, nits: 94.6), percent + " • ≈95 нит")
    }

    func testSettingsDecodeWithoutLuminanceAndRoundTrip() throws {
        let old = try JSONDecoder().decode(DisplayBrightnessSettings.self, from: Data(#"{"keyboardEnabled":true}"#.utf8))
        XCTAssertTrue(old.luminance.isEmpty)
        XCTAssertTrue(old.keyboardEnabled)
        let partial = try JSONDecoder().decode(DisplayBrightnessSettings.self,
                                               from: Data(#"{"luminance":{"UUID-1":{"maximum":300}}}"#.utf8))
        XCTAssertEqual(partial.luminance["UUID-1"], BrightnessLuminanceRange(minimum: nil, maximum: 300))
        var settings = DisplayBrightnessSettings()
        settings.luminance["UUID-2"] = BrightnessLuminanceRange(minimum: 29, maximum: 350)
        let decoded = try JSONDecoder().decode(DisplayBrightnessSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }
}

@MainActor private final class NitsOSDRecorder: BrightnessOSDPresenting {
    var shown: [(value: Double, nits: Double?)] = []
    func show(display: BrightnessDisplay, value: Double, nits: Double?) { shown.append((value, nits)) }
    func hide() {}
}

private actor NitsProvider: DisplayBrightnessProvider {
    let vendor: UInt32
    var raw: UInt16 = 24
    init(vendor: UInt32) { self.vendor = vendor }
    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay] {
        [BrightnessDisplay(id: "b", displayID: 2, name: "DELL U2720Q", bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                           builtIn: false, value: BrightnessDDCScale.logical(raw: raw, maximum: 100), method: methods["b"] ?? .hardware,
                           hardwareMaximum: 100, edidVendor: vendor, edidProduct: 0x41B5)]
    }
    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double {
        let target = try BrightnessDDCScale.rawTarget(value, maximum: 100); raw = target
        return try BrightnessDDCWriteTransaction.confirmLogical(target: target, maximum: 100, reading: (target, 100))
    }
    func reset() async {}
}

/// Built-in panel: macOS-reported luminance follows the confirmed brightness only after the write.
private actor BuiltInNitsProvider: DisplayBrightnessProvider {
    private var value = 1.0
    private var nits = 400.0
    private let table: [Double: Double] = [1: 400, 0.9375: 343.75]
    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay] {
        [BrightnessDisplay(id: "mac", displayID: 1, name: "Built-in", bounds: CGRect(x: 0, y: 0, width: 100, height: 100),
                           builtIn: true, value: value, method: methods["mac"] ?? .hardware, reportedNits: nits)]
    }
    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double {
        self.value = value; nits = table[value] ?? 0
        return value
    }
    func reportedNits(_ display: BrightnessDisplay) async -> Double? { nits }
    func reset() async {}
}

@MainActor final class BrightnessLuminanceModelTests: XCTestCase {
    private func settle(_ model: DisplayBrightnessModel) async {
        for _ in 0..<1000 {
            if !model.refreshing && model.pending.isEmpty && !model.displays.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("model did not settle")
    }

    func testBuiltInKeyPressShowsTheNitsMacOSReportsAfterTheWrite() async throws {
        let provider = BuiltInNitsProvider(), osd = NitsOSDRecorder()
        let model = DisplayBrightnessModel(provider: provider, osd: osd)
        let settings = DisplayBrightnessSettings()
        model.start { settings }
        await model.refresh(); await settle(model)
        XCTAssertEqual(try XCTUnwrap(model.nits(for: try XCTUnwrap(model.displays.first))), 400)
        model.handleKey(increase: false, fine: false, at: CGPoint(x: 50, y: 50)); await settle(model)
        let shown = try XCTUnwrap(osd.shown.last)
        XCTAssertEqual(shown.value, 0.9375)
        XCTAssertEqual(shown.nits, 343.75, "nits read after the write, not the stale pre-write level")
        XCTAssertEqual(model.nits(for: try XCTUnwrap(model.displays.first)), 343.75, "panel row matches the OSD")
        model.stop()
    }

    func testOSDAndPanelGetEstimatedNitsForKnownMonitorOnly() async throws {
        for (vendor, known) in [(UInt32(0x10AC), true), (UInt32(0x1234), false)] {
            let provider = NitsProvider(vendor: vendor), osd = NitsOSDRecorder()
            let model = DisplayBrightnessModel(provider: provider, osd: osd)
            let settings = DisplayBrightnessSettings()
            model.start { settings }
            await model.refresh(); await settle(model)
            let display = try XCTUnwrap(model.displays.first)
            model.handleKey(increase: true, fine: false, at: CGPoint(x: 50, y: 50)); await settle(model)
            let raw = await provider.raw
            let shown = try XCTUnwrap(osd.shown.last)
            XCTAssertEqual(shown.value, BrightnessDDCScale.logical(raw: raw, maximum: 100))
            if known {
                XCTAssertEqual(try XCTUnwrap(model.nits(for: display)), 29 + 321 * 0.24, accuracy: 1e-9)
                XCTAssertEqual(try XCTUnwrap(shown.nits), 29 + 321 * Double(raw) / 100, accuracy: 1e-9)
            } else {
                XCTAssertNil(model.nits(for: display)); XCTAssertNil(shown.nits)
            }
            model.stop()
        }
    }
}
