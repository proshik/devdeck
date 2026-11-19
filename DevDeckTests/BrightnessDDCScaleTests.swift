import XCTest
@testable import DevDeck

final class BrightnessDDCScaleTests: XCTestCase {
    private func raw(_ logical: Double, _ maximum: UInt16 = 100) throws -> UInt16 {
        try BrightnessDDCScale.rawTarget(logical, maximum: maximum)
    }
    private func logical(_ raw: UInt16, _ maximum: UInt16 = 100) throws -> Double {
        try XCTUnwrap(BrightnessDDCScale.logical(raw: raw, maximum: maximum))
    }

    func testCurveMapsOnePercentToDarkestHardwareLevelAndFullToMaximum() throws {
        XCTAssertEqual(BrightnessDDCScale.hardwareFraction(0), 0)
        XCTAssertEqual(BrightnessDDCScale.hardwareFraction(0.01), 0)
        XCTAssertEqual(BrightnessDDCScale.hardwareFraction(1), 1)
        XCTAssertEqual(try XCTUnwrap(BrightnessDDCScale.logicalFraction(0)), 0.01, accuracy: 1e-12,
                       "raw0 is a visible positive level, shown as 1%, not as black")
        XCTAssertEqual(BrightnessDDCScale.logicalFraction(1), 1)
        // raw = round(rawMax·((p−1)/99)^2)
        XCTAssertEqual(try XCTUnwrap(BrightnessDDCScale.hardwareFraction(0.5)), pow(49.0 / 99, 2), accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(BrightnessDDCScale.logicalFraction(0.25)), 0.01 + 0.99 * 0.5, accuracy: 1e-12)
    }

    func testDellTableHasNoRawOneFloor() throws {
        XCTAssertEqual(try raw(0.000001), 0, "smallest positive request reaches raw0")
        XCTAssertEqual(try raw(0.01), 0)
        XCTAssertEqual(try raw(0.05), 0)
        XCTAssertEqual(try raw(0.10), 1)
        XCTAssertEqual(try raw(0.25), 6)
        XCTAssertEqual(try raw(0.50), 24)
        XCTAssertEqual(try raw(0.75), 56)
        XCTAssertEqual(try raw(1), 100)
    }

    func testEveryRawLevelRoundtripsMonotonicallyForAnyReportedMaximum() throws {
        for maximum: UInt16 in [1, 10, 50, 100, 255, 1000] {
            var previous = 0.0
            for level in 0...maximum {
                let value = try logical(level, maximum)
                XCTAssertGreaterThan(value, previous, "max\(maximum) raw\(level)"); previous = value
                XCTAssertEqual(try raw(value, maximum), level, "max\(maximum) raw\(level)")
            }
            XCTAssertEqual(previous, 1, accuracy: 1e-12)
            XCTAssertEqual(try raw(1, maximum), maximum)
        }
        for level: UInt16 in [0, 1, 2, 32767, 65534, 65535] {
            XCTAssertEqual(try raw(try logical(level, 65535), 65535), level)
        }
    }

    func testFiniteValuesClampAndNonfiniteCannotBecomeFakeLevel() throws {
        XCTAssertEqual(BrightnessDDCScale.hardwareFraction(-0.3), 0); XCTAssertEqual(BrightnessDDCScale.hardwareFraction(1.3), 1)
        XCTAssertEqual(try XCTUnwrap(BrightnessDDCScale.logicalFraction(-0.3)), 0.01, accuracy: 1e-12)
        XCTAssertEqual(BrightnessDDCScale.logicalFraction(1.3), 1)
        for transform in [BrightnessDDCScale.hardwareFraction, BrightnessDDCScale.logicalFraction] {
            for bad in [Double.nan, .infinity, -.infinity] { XCTAssertNil(transform(bad)) }
        }
        XCTAssertThrowsError(try raw(.nan))
        XCTAssertThrowsError(try raw(0.5, 0))
        XCTAssertNil(BrightnessDDCScale.logical(raw: 101, maximum: 100))
        XCTAssertNil(BrightnessDDCScale.logical(raw: 0, maximum: 0))
    }

    func testKeyStepsFromBlackStartAtRawZeroAndMoveAtLeastOneRawEveryPress() throws {
        for maximum: UInt16 in [10, 100, 255, 65535] {
            for step in [1.0 / 16, 1.0 / 64] {
                var value = BrightnessDDCScale.keyTarget(from: 0, step: step, maximum: maximum)
                XCTAssertEqual(try raw(value, maximum), 0, "max\(maximum): first up from black is raw0")
                var previous = try raw(value, maximum)
                for _ in 0..<200 where previous < maximum {
                    value = BrightnessDDCScale.keyTarget(from: value, step: step, maximum: maximum)
                    let next = try raw(value, maximum)
                    XCTAssertGreaterThan(next, previous, "max\(maximum) step\(step): plateau at raw\(previous)")
                    previous = next
                }
                XCTAssertEqual(previous, maximum)
                XCTAssertEqual(BrightnessDDCScale.keyTarget(from: 1, step: step, maximum: maximum), 1, "upper edge stays")
            }
        }
    }

    func testKeyStepsDownVisitRawZeroBeforeBlack() throws {
        for maximum: UInt16 in [10, 100, 255] {
            for step in [-1.0 / 16, -1.0 / 64] {
                var value = 1.0, levels: [UInt16] = []
                for _ in 0..<400 {
                    value = BrightnessDDCScale.keyTarget(from: value, step: step, maximum: maximum)
                    if value == 0 { break }
                    let level = try raw(value, maximum)
                    if let last = levels.last { XCTAssertLessThan(level, last, "max\(maximum) step\(step)") }
                    levels.append(level)
                }
                XCTAssertEqual(value, 0, "down keys end at the black endpoint")
                XCTAssertEqual(levels.last, 0, "max\(maximum) step\(step): raw0 is reachable on the way down")
                XCTAssertEqual(BrightnessDDCScale.keyTarget(from: 0, step: step, maximum: maximum), 0)
            }
        }
    }

    func testRawZeroConfirmsAsPositiveAndMismatchIsCheckedInRawUnits() throws {
        XCTAssertEqual(try BrightnessDDCWriteTransaction.confirmLogical(target: 0, maximum: 100, reading: (0, 100)), 0.01, accuracy: 1e-12)
        XCTAssertEqual(try BrightnessDDCWriteTransaction.confirmLogical(target: 24, maximum: 100, reading: (24, 100)), try logical(24), accuracy: 1e-12)
        XCTAssertEqual(try BrightnessDDCWriteTransaction.confirmLogical(target: 24, maximum: 100, reading: (25, 100)), try logical(25), accuracy: 1e-12)
        XCTAssertThrowsError(try BrightnessDDCWriteTransaction.confirmLogical(target: 94, maximum: 100, reading: (99, 100))) { error in
            guard case BrightnessFailure.unconfirmed(let actual) = error else { return XCTFail("expected raw mismatch") }
            XCTAssertEqual(actual, try! self.logical(99), accuracy: 1e-12)
        }
        XCTAssertEqual(try BrightnessDDCWriteTransaction.confirmLogical(target: 3, maximum: 255, reading: (3, 255)), try logical(3, 255), accuracy: 1e-12)
        for reading: (UInt16, UInt16) in [(101, 100), (10, 0), (10, 200)] {
            XCTAssertThrowsError(try BrightnessDDCWriteTransaction.confirmLogical(target: 10, maximum: 100, reading: reading))
        }
    }
}

private actor ScaledProvider: DisplayBrightnessProvider {
    var raw: UInt16 = 10
    let maximum: UInt16
    var apple = 0.5, software = 0.5
    var calls: [(String, Double)] = []
    var nextReadback: UInt16?
    var externalDisplayID: UInt32 = 2
    var holdDiscovery = false, discoveryWaiting = false
    private var discoveryGate: CheckedContinuation<Void, Never>?
    init(maximum: UInt16 = 100) { self.maximum = maximum }
    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay] {
        if holdDiscovery {
            holdDiscovery = false; discoveryWaiting = true
            await withCheckedContinuation { discoveryGate = $0 }
            discoveryWaiting = false
        }
        return ["a", "b"].map { id in
            let method = methods[id] ?? .hardware
            let ddc = id == "b" && method == .hardware
            let value = method == .software ? software : (id == "a" ? apple : BrightnessDDCScale.logical(raw: raw, maximum: maximum)!)
            return BrightnessDisplay(id: id, displayID: id == "a" ? 1 : externalDisplayID, name: id,
                bounds: CGRect(x: id == "a" ? 0 : 100, y: 0, width: 100, height: 100),
                builtIn: id == "a", value: value, method: method, hardwareMaximum: ddc ? maximum : nil)
        }
    }
    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double {
        calls.append((display.id, value))
        if display.method == .software { software = max(0.1, value); return software }
        if display.id == "a" { apple = value; return apple }
        let target = try BrightnessDDCScale.rawTarget(value, maximum: maximum)
        raw = nextReadback ?? target; nextReadback = nil
        return try BrightnessDDCWriteTransaction.confirmLogical(target: target, maximum: maximum, reading: (raw, maximum))
    }
    func overrideNextReadback(_ value: UInt16) { nextReadback = value }
    func externalRaw(_ value: UInt16) { raw = value }
    func replaceExternalDisplay() { externalDisplayID = 3 }
    func pauseDiscovery() { holdDiscovery = true }
    func releaseDiscovery() { discoveryGate?.resume(); discoveryGate = nil }
    func reset() async {}
}

@MainActor final class BrightnessDDCScaleModelTests: XCTestCase {
    private let dell = CGPoint(x: 150, y: 50)
    private func settled(_ model: DisplayBrightnessModel) async {
        for _ in 0..<1000 {
            if !model.refreshing && model.pending.isEmpty && !model.displays.isEmpty { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("model did not settle")
    }
    private func logical(_ raw: UInt16, _ maximum: UInt16 = 100) -> Double {
        BrightnessDDCScale.logical(raw: raw, maximum: maximum)!
    }
    private func offscreenBlackout() -> BrightnessBlackoutController {
        BrightnessBlackoutController(target: { display in
            BrightnessBlackoutTarget(id: display.id, displayID: display.displayID,
                frame: CGRect(x: -4000, y: -4000, width: 160, height: 100))
        })
    }
    private func press(_ model: DisplayBrightnessModel, up: Bool, fine: Bool, at point: CGPoint? = nil) async {
        model.handleKey(increase: up, fine: fine, at: point ?? dell)
        await settled(model)
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
        var raw = await provider.raw; XCTAssertEqual(raw, 24)
        settings.linkSliders = false
        await press(model, up: true, fine: false)
        calls = await provider.calls
        XCTAssertEqual(calls.count, 3); XCTAssertEqual(calls.last?.0, "b")
        XCTAssertEqual(try XCTUnwrap(calls.last?.1), logical(24) + 0.0625, accuracy: 1e-12)
        let before = try XCTUnwrap(model.displays.last?.value)
        settings.linkKeys = true
        await press(model, up: false, fine: false)
        calls = await provider.calls
        XCTAssertEqual(calls.count, 5)
        XCTAssertTrue(calls.suffix(2).allSatisfy { abs($0.1 - (before - 0.0625)) < 1e-12 })
        raw = await provider.raw
        XCTAssertEqual(raw, try BrightnessDDCScale.rawTarget(before - 0.0625, maximum: 100))
        XCTAssertEqual(try XCTUnwrap(model.displays.first?.value), before - 0.0625, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(model.displays.last?.value), logical(raw), accuracy: 1e-12)
    }

    func testNormalKeysFromBlackGiveRawZeroThenANewLevelEveryPress() async {
        let provider = ScaledProvider(), blackout = offscreenBlackout()
        let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
        defer { model.stop() }
        await model.refresh(); await model.apply(id: "b", value: 0)
        let initial = await provider.calls; XCTAssertTrue(initial.isEmpty)
        XCTAssertNotNil(blackout.panels["b"])
        model.handleKey(increase: true, fine: false, at: dell)
        XCTAssertNil(blackout.panels["b"])
        await settled(model)
        var levels: [UInt16] = [], shown: [Double] = []
        levels.append(await provider.raw); shown.append(model.displays.last?.value ?? -1)
        for _ in 1..<16 {
            await press(model, up: true, fine: false)
            levels.append(await provider.raw); shown.append(model.displays.last?.value ?? -1)
        }
        XCTAssertEqual(levels, [0, 1, 3, 5, 8, 12, 17, 23, 29, 37, 45, 53, 63, 74, 85, 97])
        XCTAssertEqual(shown.first ?? -1, 0.01, accuracy: 1e-12, "raw0 is shown as 1%")
        XCTAssertEqual(shown, levels.map { logical($0) }, "OSD/panel show the confirmed raw, not the request")
    }

    func testFineKeysFromBlackAdvanceOneRawAtTheLowEnd() async {
        let provider = ScaledProvider(), blackout = offscreenBlackout()
        let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
        defer { model.stop() }
        await model.refresh(); await model.apply(id: "b", value: 0)
        var levels: [UInt16] = []
        for _ in 0..<10 {
            await press(model, up: true, fine: true)
            levels.append(await provider.raw)
        }
        XCTAssertEqual(levels, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9])
    }

    func testKeysWithNonPercentMaximumNeverPlateau() async {
        for maximum: UInt16 in [10, 255] {
            for fine in [false, true] {
                let provider = ScaledProvider(maximum: maximum); await provider.externalRaw(0)
                let model = DisplayBrightnessModel(provider: provider, blackout: offscreenBlackout())
                await model.refresh()
                var previous = await provider.raw
                for _ in 0..<300 where previous < maximum {
                    await press(model, up: true, fine: fine)
                    let next = await provider.raw
                    XCTAssertGreaterThan(next, previous, "max\(maximum) fine\(fine)")
                    previous = next
                }
                XCTAssertEqual(previous, maximum)
                model.stop()
            }
        }
    }

    func testMismatchPublishesInverseActualWhileAppleAndSoftwareKeepDirectScale() async throws {
        let provider = ScaledProvider(), model = DisplayBrightnessModel(provider: provider)
        var settings = DisplayBrightnessSettings()
        model.start { settings }; defer { model.stop() }
        await model.refresh(); await settled(model)
        await provider.overrideNextReadback(99)
        await model.apply(id: "b", value: 0.5)
        XCTAssertEqual(try XCTUnwrap(model.displays.last?.value), logical(99), accuracy: 1e-12)
        XCTAssertNotNil(model.errors["b"])
        await model.apply(id: "a", value: 0.45)
        XCTAssertEqual(model.displays.first?.value, 0.45)
        settings.methods["b"] = .software
        await model.refresh(); await settled(model)
        XCTAssertNil(model.displays.last?.hardwareMaximum)
        await model.apply(id: "b", value: 0.45)
        XCTAssertEqual(model.displays.last?.value, 0.45)
        let raw = await provider.raw; XCTAssertEqual(raw, 99)
    }

    func testAppleKeysKeepPlainLogicalSteps() async {
        let provider = ScaledProvider(), model = DisplayBrightnessModel(provider: provider)
        defer { model.stop() }
        await model.refresh()
        await press(model, up: true, fine: true, at: CGPoint(x: 50, y: 50))
        let calls = await provider.calls
        XCTAssertEqual(calls.map(\.1), [0.5 + 1.0 / 64])
    }

    func testDownKeysReachRawZeroThenBlackAndUpRecovers() async {
        for fine in [false, true] {
            let provider = ScaledProvider(); await provider.externalRaw(1)
            let blackout = offscreenBlackout()
            let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
            await model.refresh()
            await press(model, up: false, fine: fine)
            var raw = await provider.raw
            XCTAssertEqual(raw, 0, "fine\(fine): raw1 → raw0, never skipped")
            XCTAssertEqual(model.displays.last?.value ?? -1, 0.01, accuracy: 1e-12)
            XCTAssertNil(blackout.panels["b"])
            await press(model, up: false, fine: fine)
            XCTAssertEqual(model.displays.last?.value, 0)
            XCTAssertNotNil(blackout.panels["b"])
            var calls = await provider.calls
            XCTAssertEqual(calls.count, 1, "black is image-only, no SET")
            await press(model, up: true, fine: fine)
            XCTAssertNil(blackout.panels["b"])
            calls = await provider.calls; XCTAssertEqual(calls.count, 2)
            raw = await provider.raw; XCTAssertEqual(raw, 0)
            XCTAssertEqual(model.displays.last?.value ?? -1, 0.01, accuracy: 1e-12)
            model.stop()
        }
    }

    func testCompletedFineUpKeysCrossLevelsEvenAcrossUnchangedDiscovery() async {
        let provider = ScaledProvider(); await provider.externalRaw(1)
        let model = DisplayBrightnessModel(provider: provider); defer { model.stop() }
        await model.refresh()
        var levels: [UInt16] = []
        for _ in 0..<3 {
            await press(model, up: true, fine: true)
            levels.append(await provider.raw)
            await model.refresh() // Own quantized readback must not erase residual intent.
        }
        XCTAssertEqual(levels, [2, 3, 4])
        XCTAssertEqual(model.displays.last?.value, logical(4))
    }

    func testIntentResetsForSliderTargetExternalMethodIdentityAndLinkedScopeChanges() async throws {
        let provider = ScaledProvider(); await provider.externalRaw(1)
        let model = DisplayBrightnessModel(provider: provider)
        var settings = DisplayBrightnessSettings()
        model.start { settings }; defer { model.stop() }
        await model.refresh(); await settled(model)
        func expectedFineUp(from base: Double) -> Double {
            BrightnessDDCScale.keyTarget(from: base, step: 1.0 / 64, maximum: 100)
        }
        func fineUpB() async { await press(model, up: true, fine: true) }
        await fineUpB()
        model.request(id: "b", value: 0.25); await settled(model)
        await fineUpB()
        var calls = await provider.calls
        XCTAssertEqual(try XCTUnwrap(calls.last?.1), expectedFineUp(from: logical(6)), accuracy: 1e-12, "slider is the new base")
        model.handleKey(increase: true, fine: true, at: CGPoint(x: 50, y: 50)); await settled(model)
        let actualAfterReturn = try XCTUnwrap(model.displays.last?.value)
        await fineUpB()
        calls = await provider.calls
        XCTAssertEqual(try XCTUnwrap(calls.last?.1), expectedFineUp(from: actualAfterReturn), accuracy: 1e-12,
                       "returning cursor starts from actual, not old target session")
        await provider.externalRaw(10); await model.refresh()
        await fineUpB()
        calls = await provider.calls
        XCTAssertEqual(try XCTUnwrap(calls.last?.1), expectedFineUp(from: logical(10)), accuracy: 1e-12)
        settings.methods["b"] = .software; await model.refresh()
        await fineUpB()
        calls = await provider.calls; XCTAssertEqual(calls.last?.1, 0.5 + 1.0 / 64, "software uses plain steps")
        settings.methods["b"] = .hardware; await provider.externalRaw(1); await model.refresh()
        await fineUpB()
        calls = await provider.calls
        XCTAssertEqual(try XCTUnwrap(calls.last?.1), logical(2), accuracy: 1e-12)
        await provider.replaceExternalDisplay()
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for _ in 0..<1000 {
            if model.displays.last?.displayID == 3 && !model.refreshing { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertEqual(model.displays.last?.displayID, 3)
        await fineUpB()
        calls = await provider.calls
        XCTAssertEqual(try XCTUnwrap(calls.last?.1), logical(3), accuracy: 1e-12, "new identity starts from actual raw2")
        settings.linkKeys = true
        await fineUpB()
        calls = await provider.calls
        XCTAssertEqual(Set(calls.suffix(2).map(\.0)), ["a", "b"])
        let linkedTarget = expectedFineUp(from: logical(3))
        XCTAssertTrue(calls.suffix(2).allSatisfy { abs($0.1 - linkedTarget) < 1e-12 })
    }

    func testFailedReadbackDiscardsIntentBeforeNextCompletedKey() async throws {
        let provider = ScaledProvider(); await provider.externalRaw(1)
        let model = DisplayBrightnessModel(provider: provider); defer { model.stop() }
        await model.refresh()
        await press(model, up: true, fine: true)
        await provider.overrideNextReadback(99)
        await press(model, up: true, fine: true)
        let actual = try XCTUnwrap(model.displays.last?.value)
        XCTAssertEqual(actual, logical(99), accuracy: 1e-12)
        XCTAssertNotNil(model.errors["b"])
        await press(model, up: false, fine: true)
        let calls = await provider.calls
        XCTAssertEqual(try XCTUnwrap(calls.last?.1), actual - 1.0 / 64, accuracy: 1e-12)
    }

    func testCompletedFineKeysLeaveEveryLevelInBothDirectionsAcrossHardwareRange() async {
        for initial: UInt16 in [0, 1, 2, 5, 10, 50, 99] {
            for increase in [false, true] {
                let provider = ScaledProvider(); await provider.externalRaw(initial)
                let blackout = offscreenBlackout()
                let model = DisplayBrightnessModel(provider: provider, blackout: blackout)
                await model.refresh()
                await press(model, up: increase, fine: true)
                let raw = await provider.raw
                let movedToBlack = model.displays.last?.value == 0
                XCTAssertTrue(raw != initial || movedToBlack, "fine key stuck at raw\(initial), increase=\(increase)")
                if increase { XCTAssertGreaterThan(raw, initial) }
                if initial == 0 && !increase { XCTAssertNotNil(blackout.panels["b"], "fine DOWN from raw0 reaches black") }
                model.stop()
            }
        }
    }

    func testExternalChangeDuringHeldDiscoveryDiscardsQueuedKeyFromOldBaseline() async {
        let provider = ScaledProvider(); await provider.externalRaw(1)
        let model = DisplayBrightnessModel(provider: provider); defer { model.stop() }
        await model.refresh()
        await press(model, up: true, fine: true)
        await provider.pauseDiscovery()
        let discovery = Task { await model.refresh() }
        for _ in 0..<1000 {
            if await provider.discoveryWaiting { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        await provider.externalRaw(10)
        model.handleKey(increase: true, fine: true, at: dell)
        XCTAssertNotNil(model.pending["b"])
        await provider.releaseDiscovery(); await discovery.value; await settled(model)
        var calls = await provider.calls
        XCTAssertEqual(calls.count, 1, "stale queued key cannot overwrite discovered external brightness")
        XCTAssertEqual(model.displays.last?.value, logical(10))
        await press(model, up: true, fine: true)
        calls = await provider.calls
        XCTAssertEqual(try XCTUnwrap(calls.last?.1),
                       BrightnessDDCScale.keyTarget(from: logical(10), step: 1.0 / 64, maximum: 100), accuracy: 1e-12)
    }
}
