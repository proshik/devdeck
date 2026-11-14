import XCTest
@testable import DevDeck

final class BrightnessDDCScaleTests: XCTestCase {
    func testCurveEndpointsMidpointAndMonotonicRoundtrip() throws {
        XCTAssertEqual(BrightnessDDCScale.hardwareFraction(0), 0)
        XCTAssertEqual(BrightnessDDCScale.hardwareFraction(1), 1)
        XCTAssertEqual(try XCTUnwrap(BrightnessDDCScale.hardwareFraction(0.5)), 0.1, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(BrightnessDDCScale.logicalFraction(0.1)), 0.5, accuracy: 1e-12)
        var previous = -1.0
        for step in 0...1000 {
            let logical = Double(step) / 1000
            let raw = try XCTUnwrap(BrightnessDDCScale.hardwareFraction(logical))
            XCTAssertGreaterThan(raw, previous); previous = raw
            XCTAssertEqual(try XCTUnwrap(BrightnessDDCScale.logicalFraction(raw)), logical, accuracy: 1e-12)
        }
    }
    func testFiniteValuesClampAndNonfiniteCannotBecomeFakeZero() throws {
        for transform in [BrightnessDDCScale.hardwareFraction, BrightnessDDCScale.logicalFraction] {
            XCTAssertEqual(transform(-0.3), 0); XCTAssertEqual(transform(1.3), 1)
            for bad in [Double.nan, .infinity, -.infinity] { XCTAssertNil(transform(bad)) }
        }
        XCTAssertThrowsError(try BrightnessDDCScale.rawTarget(.nan, maximum: 100))
        XCTAssertThrowsError(try BrightnessDDCScale.rawTarget(0.5, maximum: 0))
    }
    func testHardwareQuantizationRoundtripsAndPositiveInputNeverRoundsToZero() throws {
        for maximum: UInt16 in [10, 100, 255, 65535] {
            for raw: UInt16 in [0, 1, maximum / 2, maximum - 1, maximum] {
                let logical = try XCTUnwrap(BrightnessDDCScale.logicalFraction(Double(raw) / Double(maximum)))
                XCTAssertEqual(try BrightnessDDCScale.rawTarget(logical, maximum: maximum), raw)
            }
            XCTAssertEqual(try BrightnessDDCScale.rawTarget(0.000001, maximum: maximum), 1)
        }
        XCTAssertEqual(try BrightnessDDCScale.rawTarget(0.25, maximum: 100), 1)
        XCTAssertEqual(try BrightnessDDCScale.rawTarget(0.5, maximum: 100), 10)
        XCTAssertEqual(try BrightnessDDCScale.rawTarget(0.75, maximum: 100), 38)
        let lowest = try BrightnessDDCWriteTransaction.confirmLogical(target: 1, maximum: 100, reading: (1, 100))
        XCTAssertEqual(lowest, 0.25, accuracy: 1e-12, "first positive hardware step is shown honestly, not as requested6.25%")
        XCTAssertEqual(try XCTUnwrap(BrightnessDDCScale.logicalFraction(0.99)), 0.99698, accuracy: 0.00001)
    }
    func testMismatchIsCheckedInRawUnitsAndRetainsInverseObservedValue() throws {
        XCTAssertEqual(try BrightnessDDCWriteTransaction.confirmLogical(target: 10, maximum: 100, reading: (10, 100)), 0.5, accuracy: 1e-12)
        XCTAssertEqual(try BrightnessDDCWriteTransaction.confirmLogical(target: 10, maximum: 100, reading: (11, 100)), try XCTUnwrap(BrightnessDDCScale.logicalFraction(0.11)), accuracy: 1e-12)
        XCTAssertThrowsError(try BrightnessDDCWriteTransaction.confirmLogical(target: 94, maximum: 100, reading: (99, 100))) { error in
            guard case BrightnessFailure.unconfirmed(let actual) = error else { return XCTFail("expected raw mismatch") }
            XCTAssertEqual(actual, 0.99698, accuracy: 0.00001)
        }
        XCTAssertThrowsError(try BrightnessDDCWriteTransaction.confirmLogical(target: 1, maximum: 100, reading: (0, 100)), "a positive target must not silently confirm zero")
        for reading: (UInt16, UInt16) in [(101,100), (10,0), (10,200)] {
            XCTAssertThrowsError(try BrightnessDDCWriteTransaction.confirmLogical(target: 10, maximum: 100, reading: reading))
        }
    }
}

private actor ScaledProvider: DisplayBrightnessProvider {
    var raw: UInt16 = 10
    var apple = 0.5, software = 0.5
    var calls: [(String, Double)] = []
    var nextReadback: UInt16?
    var externalDisplayID: UInt32 = 2
    var holdDiscovery = false, discoveryWaiting = false
    private var discoveryGate: CheckedContinuation<Void, Never>?
    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay] {
        if holdDiscovery {
            holdDiscovery = false; discoveryWaiting = true
            await withCheckedContinuation { discoveryGate = $0 }
            discoveryWaiting = false
        }
        return ["a", "b"].map { id in
            let method = methods[id] ?? .hardware
            let value = method == .software ? software : (id == "a" ? apple : BrightnessDDCScale.logicalFraction(Double(raw) / 100)!)
            return BrightnessDisplay(id: id, displayID: id == "a" ? 1 : externalDisplayID, name: id,
                bounds: CGRect(x: id == "a" ? 0 : 100, y: 0, width: 100, height: 100),
                builtIn: id == "a", value: value, method: method)
        }
    }
    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double {
        calls.append((display.id, value))
        if display.method == .software { software = max(0.1, value); return software }
        if display.id == "a" { apple = value; return apple }
        let target = try BrightnessDDCScale.rawTarget(value, maximum: 100)
        raw = nextReadback ?? target; nextReadback = nil
        return try BrightnessDDCWriteTransaction.confirmLogical(target: target, maximum: 100, reading: (raw, 100))
    }
    func overrideNextReadback(_ value: UInt16) { nextReadback = value }
    func externalRaw(_ value: UInt16) { raw = value }
    func replaceExternalDisplay() { externalDisplayID = 3 }
    func pauseDiscovery() { holdDiscovery = true }
    func releaseDiscovery() { discoveryGate?.resume(); discoveryGate = nil }
    func reset() async {}
}

@MainActor final class BrightnessDDCScaleModelTests: XCTestCase {
    private func settled(_ model: DisplayBrightnessModel) async {
        for _ in 0..<1000 {
            if !model.refreshing && model.pending.isEmpty && !model.displays.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("model did not settle")
    }
    func testLinkedSlidersAndKeysSendLogicalValuesBeforePerProviderQuantization() async throws {
        let provider = ScaledProvider(), model = DisplayBrightnessModel(provider: provider)
        var settings = DisplayBrightnessSettings(); settings.linkSliders = true
        model.start { settings }; defer { model.stop() }
        await model.refresh(); await settled(model)
        model.request(id: "a", value: 0.5)
        await settled(model)
        var calls = await provider.calls
        XCTAssertEqual(calls.count, 2); XCTAssertTrue(calls.allSatisfy { $0.1 == 0.5 })
        var raw = await provider.raw; XCTAssertEqual(raw, 10)
        settings.linkSliders = false
        model.handleKey(increase: true, fine: false, at: CGPoint(x: 150, y: 50))
        await settled(model)
        calls = await provider.calls
        XCTAssertEqual(calls.count, 3); XCTAssertEqual(calls.last?.0, "b"); XCTAssertEqual(calls.last?.1, 0.5625)
        let before = try XCTUnwrap(model.displays.last?.value)
        settings.linkKeys = true
        model.handleKey(increase: false, fine: false, at: CGPoint(x: 150, y: 50))
        await settled(model)
        calls = await provider.calls
        XCTAssertEqual(calls.count, 5)
        XCTAssertTrue(calls.suffix(2).allSatisfy { abs($0.1 - (before - 0.0625)) < 1e-12 })
        raw = await provider.raw
        XCTAssertEqual(raw, try BrightnessDDCScale.rawTarget(before - 0.0625, maximum: 100))
        XCTAssertEqual(try XCTUnwrap(model.displays.first?.value), before - 0.0625, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(model.displays.last?.value), try XCTUnwrap(BrightnessDDCScale.logicalFraction(Double(raw) / 100)), accuracy: 1e-12)
    }
    func testKeyUpEscapesZeroAtFirstRepresentableHardwareStepThenAdvances() async {
        let provider = ScaledProvider()
        let blackout = BrightnessBlackoutController(target: { display in
            BrightnessBlackoutTarget(id: display.id, displayID: display.displayID,
                frame: CGRect(x: -4000, y: -4000, width: 160, height: 100))
        })
        let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
        defer { model.stop() }
        await model.refresh(); await model.apply(id: "b", value: 0)
        let initial = await provider.calls; XCTAssertTrue(initial.isEmpty)
        XCTAssertNotNil(blackout.panels["b"])
        model.handleKey(increase: true, fine: false, at: CGPoint(x: 150, y: 50))
        XCTAssertNil(blackout.panels["b"])
        await settled(model)
        XCTAssertEqual(model.displays.last?.value ?? -1, 0.25, accuracy: 1e-12)
        var raw = await provider.raw; XCTAssertEqual(raw, 1)
        for _ in 0..<4 {
            model.handleKey(increase: true, fine: false, at: CGPoint(x: 150, y: 50))
            await settled(model)
        }
        raw = await provider.raw; XCTAssertEqual(raw, 2)
        XCTAssertGreaterThan(model.displays.last?.value ?? 0, 0.25)
        let calls = await provider.calls; XCTAssertEqual(calls.map(\.1), [0.0625, 0.125, 0.1875, 0.25, 0.3125])
    }
    func testMismatchPublishesInverseActualWhileAppleAndSoftwareKeepDirectScale() async throws {
        let provider = ScaledProvider(), model = DisplayBrightnessModel(provider: provider)
        var settings = DisplayBrightnessSettings()
        model.start { settings }; defer { model.stop() }
        await model.refresh(); await settled(model)
        await provider.overrideNextReadback(99)
        await model.apply(id: "b", value: 0.5)
        XCTAssertEqual(try XCTUnwrap(model.displays.last?.value), 0.99698, accuracy: 0.00001)
        XCTAssertNotNil(model.errors["b"])
        await model.apply(id: "a", value: 0.45)
        XCTAssertEqual(model.displays.first?.value, 0.45)
        settings.methods["b"] = .software
        await model.refresh(); await settled(model)
        await model.apply(id: "b", value: 0.45)
        XCTAssertEqual(model.displays.last?.value, 0.45)
        let raw = await provider.raw; XCTAssertEqual(raw, 99)
    }
    func testCompletedDownKeysReachBlackFromLowestHardwareStepAndUpRecovers() async {
        let provider = ScaledProvider(); await provider.externalRaw(1)
        let blackout = BrightnessBlackoutController(target: { display in
            BrightnessBlackoutTarget(id: display.id, displayID: display.displayID,
                frame: CGRect(x: -4000, y: -4000, width: 160, height: 100))
        })
        let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
        defer { model.stop() }
        await model.refresh()
        for _ in 0..<4 {
            model.handleKey(increase: false, fine: false, at: CGPoint(x: 150, y: 50))
            await settled(model)
        }
        XCTAssertEqual(model.displays.last?.value, 0)
        XCTAssertNotNil(blackout.panels["b"])
        var calls = await provider.calls
        XCTAssertEqual(calls.map(\.1), [0.1875, 0.125, 0.0625], "fourth key is image-only zero, no SET")
        model.handleKey(increase: true, fine: false, at: CGPoint(x: 150, y: 50))
        XCTAssertNil(blackout.panels["b"])
        await settled(model)
        calls = await provider.calls; XCTAssertEqual(calls.last?.1, 0.0625)
        XCTAssertEqual(model.displays.last?.value, 0.25)
    }
    func testCompletedFineUpKeysCrossPlateauEvenAcrossUnchangedDiscovery() async {
        let provider = ScaledProvider(); await provider.externalRaw(1)
        let model = DisplayBrightnessModel(provider: provider); defer { model.stop() }
        await model.refresh()
        for index in 0..<3 {
            model.handleKey(increase: true, fine: true, at: CGPoint(x: 150, y: 50))
            await settled(model)
            if index < 2 { XCTAssertEqual(model.displays.last?.value, 0.25) }
            await model.refresh() // Own quantized readback must not erase residual intent.
        }
        let calls = await provider.calls
        XCTAssertEqual(calls.map(\.1), [0.265625, 0.28125, 0.296875])
        let raw = await provider.raw; XCTAssertEqual(raw, 2)
        XCTAssertEqual(model.displays.last?.value, BrightnessDDCScale.logicalFraction(0.02))
    }
    func testIntentResetsForSliderTargetExternalMethodIdentityAndLinkedScopeChanges() async throws {
        let provider = ScaledProvider(); await provider.externalRaw(1)
        let model = DisplayBrightnessModel(provider: provider)
        var settings = DisplayBrightnessSettings()
        model.start { settings }; defer { model.stop() }
        await model.refresh(); await settled(model)
        func fineUpB() async {
            model.handleKey(increase: true, fine: true, at: CGPoint(x: 150, y: 50))
            await settled(model)
        }
        await fineUpB()
        model.request(id: "b", value: 0.25); await settled(model)
        await fineUpB()
        var calls = await provider.calls; XCTAssertEqual(calls.last?.1, 0.265625)
        model.handleKey(increase: true, fine: true, at: CGPoint(x: 50, y: 50)); await settled(model)
        await fineUpB()
        calls = await provider.calls; XCTAssertEqual(calls.last?.1, 0.265625, "returning cursor starts from actual, not old target session")
        await provider.externalRaw(10); await model.refresh()
        await fineUpB()
        calls = await provider.calls; XCTAssertEqual(calls.last?.1, 0.515625)
        settings.methods["b"] = .software; await model.refresh()
        await fineUpB()
        calls = await provider.calls; XCTAssertEqual(calls.last?.1, 0.515625)
        settings.methods["b"] = .hardware; await provider.externalRaw(1); await model.refresh()
        await fineUpB()
        calls = await provider.calls; XCTAssertEqual(calls.last?.1, 0.265625)
        await provider.replaceExternalDisplay()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<1000 {
            if model.displays.last?.displayID == 3 && !model.refreshing { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(model.displays.last?.displayID, 3)
        await fineUpB()
        calls = await provider.calls; XCTAssertEqual(calls.last?.1, 0.265625)
        settings.linkKeys = true
        await fineUpB()
        calls = await provider.calls
        XCTAssertEqual(Set(calls.suffix(2).map(\.0)), ["a", "b"])
        XCTAssertTrue(calls.suffix(2).allSatisfy { $0.1 == 0.265625 })
    }
    func testFailedReadbackDiscardsIntentBeforeNextCompletedKey() async throws {
        let provider = ScaledProvider(); await provider.externalRaw(1)
        let model = DisplayBrightnessModel(provider: provider); defer { model.stop() }
        await model.refresh()
        model.handleKey(increase: true, fine: true, at: CGPoint(x: 150, y: 50)); await settled(model)
        await provider.overrideNextReadback(99)
        model.handleKey(increase: true, fine: true, at: CGPoint(x: 150, y: 50)); await settled(model)
        let actual = try XCTUnwrap(model.displays.last?.value)
        XCTAssertNotNil(model.errors["b"])
        model.handleKey(increase: false, fine: true, at: CGPoint(x: 150, y: 50)); await settled(model)
        let calls = await provider.calls
        XCTAssertEqual(try XCTUnwrap(calls.last?.1), actual - 1.0 / 64, accuracy: 1e-12)
    }
    func testCompletedFineKeysLeavePlateausInBothDirectionsAcrossHardwareRange() async {
        for initial: UInt16 in [1, 2, 5, 10, 50, 99] {
            for increase in [false, true] {
                let provider = ScaledProvider(); await provider.externalRaw(initial)
                let blackout = BrightnessBlackoutController(target: { display in
                    BrightnessBlackoutTarget(id: display.id, displayID: display.displayID,
                        frame: CGRect(x: -4000, y: -4000, width: 160, height: 100))
                })
                let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
                await model.refresh()
                var advanced = false
                for _ in 0..<64 {
                    model.handleKey(increase: increase, fine: true, at: CGPoint(x: 150, y: 50))
                    await settled(model)
                    let raw = await provider.raw
                    if raw != initial || model.displays.last?.value == 0 { advanced = true; break }
                }
                XCTAssertTrue(advanced, "fine keys stuck at raw\(initial), increase=\(increase)")
                if initial == 1 && !increase { XCTAssertNotNil(blackout.panels["b"], "fine DOWN must also reach black") }
                model.stop()
            }
        }
    }
    func testExternalChangeDuringHeldDiscoveryDiscardsQueuedKeyFromOldBaseline() async {
        let provider = ScaledProvider(); await provider.externalRaw(1)
        let model = DisplayBrightnessModel(provider: provider); defer { model.stop() }
        await model.refresh()
        model.handleKey(increase: true, fine: true, at: CGPoint(x: 150, y: 50)); await settled(model)
        await provider.pauseDiscovery()
        let discovery = Task { await model.refresh() }
        for _ in 0..<1000 {
            if await provider.discoveryWaiting { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        await provider.externalRaw(10)
        model.handleKey(increase: true, fine: true, at: CGPoint(x: 150, y: 50))
        XCTAssertNotNil(model.pending["b"])
        await provider.releaseDiscovery(); await discovery.value; await settled(model)
        var calls = await provider.calls
        XCTAssertEqual(calls.count, 1, "stale queued key cannot overwrite discovered external brightness")
        XCTAssertEqual(model.displays.last?.value, 0.5)
        model.handleKey(increase: true, fine: true, at: CGPoint(x: 150, y: 50)); await settled(model)
        calls = await provider.calls; XCTAssertEqual(calls.last?.1, 0.515625)
    }
}
