import XCTest
import CoreGraphics
@testable import DevDeck

/// `DevDeck automation brightness …` (AUTO-01, «Яркость из CLI»): argument parsing and the wire
/// format here; what a request does — over the real `DisplayBrightnessModel` with a fake
/// provider, OSD and blackout — in `BrightnessAutomationTests`.
final class AutomationBrightnessParsingTests: XCTestCase {

    private func parse(_ args: [String]) -> Result<AutomationCLI.Invocation, AutomationCLI.UsageError> {
        AutomationCLI.parse(args, currentDirectory: "/Users/someone", isDevelopmentBuild: false)
    }

    private func brightness(_ args: [String]) -> AutomationBrightnessRequest? {
        guard case .success(.request(let request, _)) = parse(["brightness"] + args) else { return nil }
        XCTAssertEqual(request.operation, .brightness)
        return request.brightness
    }

    private func usage(_ args: [String]) -> String? {
        guard case .failure(let error) = parse(["brightness"] + args) else { return nil }
        return error.message
    }

    func testListAndGet() {
        XCTAssertEqual(brightness(["list"]), AutomationBrightnessRequest(action: .list))
        XCTAssertEqual(brightness(["get"]), AutomationBrightnessRequest(action: .get))
        XCTAssertEqual(brightness(["get", "--display", "DELL U2720Q"]),
                       AutomationBrightnessRequest(action: .get, display: "DELL U2720Q"))
    }

    func testSetTakesAPercentFromZeroToHundred() {
        XCTAssertEqual(brightness(["set", "50"]), AutomationBrightnessRequest(action: .set, percent: 50))
        XCTAssertEqual(brightness(["set", "0"]), AutomationBrightnessRequest(action: .set, percent: 0))
        XCTAssertEqual(brightness(["set", "100", "--display", "id-1"]),
                       AutomationBrightnessRequest(action: .set, percent: 100, display: "id-1"))
        XCTAssertEqual(brightness(["set", "12.5"])?.percent, 12.5)
        for bad in ["101", "-1", "abc", "nan", "inf", ""] {
            XCTAssertNotNil(usage(["set", bad]), bad)
        }
        XCTAssertNotNil(usage(["set"]), "set needs a value")
    }

    func testUpAndDownTakeAnOptionalStep() {
        XCTAssertEqual(brightness(["up"]), AutomationBrightnessRequest(action: .up))
        XCTAssertEqual(brightness(["down", "5"]), AutomationBrightnessRequest(action: .down, percent: 5))
        XCTAssertEqual(brightness(["up", "0.5", "--display", "Built-in"]),
                       AutomationBrightnessRequest(action: .up, percent: 0.5, display: "Built-in"))
        for bad in ["0", "-3", "101", "x"] {
            XCTAssertNotNil(usage(["up", bad]), bad)
        }
    }

    func testRejectsWrongShapes() {
        XCTAssertNotNil(usage([]), "no action")
        XCTAssertNotNil(usage(["dim"]), "unknown action")
        XCTAssertNotNil(usage(["list", "--display", "a"]), "list shows every display")
        XCTAssertNotNil(usage(["list", "extra"]))
        XCTAssertNotNil(usage(["get", "extra"]))
        XCTAssertNotNil(usage(["set", "10", "20"]))
        XCTAssertNotNil(usage(["up", "1", "2"]))
        XCTAssertNotNil(usage(["get", "--display"]), "missing value")
        XCTAssertNotNil(usage(["get", "--display", ""]))
        XCTAssertNotNil(usage(["set", "10", "--timeout", "5"]), "--timeout is for run")
        XCTAssertNotNil(usage(["get", "--directory", "/tmp"]), "--directory is for run command")
        XCTAssertNotNil(usage(["get", "--brightness"]), "unknown option")
    }

    func testHelpDescribesBrightness() {
        for args in [["brightness", "--help"], ["help"]] {
            guard case .success(.help) = parse(args) else { return XCTFail("\(args) is help") }
        }
        let help = L10n.automationHelpText
        for fragment in ["automation brightness list", "brightness get", "brightness set", "brightness up|down", "--display"] {
            XCTAssertTrue(help.contains(fragment), fragment)
        }
    }

    func testWireRoundTripKeepsVersionOneAndOldRequestsStillDecode() throws {
        let request = AutomationRequest(operation: .brightness,
                                        brightness: AutomationBrightnessRequest(action: .set, percent: 40, display: "Dell"))
        XCTAssertEqual(request.version, 1)
        XCTAssertEqual(try AutomationWire.decodeRequest(AutomationWire.encode(request)), request)
        let old = try AutomationWire.decodeRequest(Data(#"{"version":1,"operation":"list"}"#.utf8))
        XCTAssertNil(old.brightness)
    }
}

// MARK: - service over the real model

@MainActor private final class CLIOSD: BrightnessOSDPresenting {
    var shown: [(id: String, value: Double)] = []
    func show(display: BrightnessDisplay, value: Double, nits: Double?) { shown.append((display.id, value)) }
    func hide() {}
}

@MainActor private final class CLIBlackout: BrightnessBlackoutPresenting {
    var covered: Set<String> = []
    private var underlying: [String: Double] = [:]
    func cover(_ display: BrightnessDisplay) throws -> Double {
        covered.insert(display.id)
        if underlying[display.id] == nil { underlying[display.id] = display.value }
        return 0
    }
    func uncover(id: String) -> Double? { covered.remove(id); return underlying.removeValue(forKey: id) }
    func reconcile(_ displays: [BrightnessDisplay]) -> [BrightnessDisplay] {
        displays.map { var d = $0; if covered.contains(d.id) { d.value = 0 }; return d }
    }
    func clear() { covered.removeAll(); underlying.removeAll() }
}

private enum IDs {
    static let builtIn = "1E3C0000-0000-4000-8000-00000000000A"
    static let dell = "37D80000-0000-4000-8000-00000000000B"
    static let projector = "C0C00000-0000-4000-8000-00000000000C"
}

private actor CLIProvider: DisplayBrightnessProvider {
    enum Failure: Sendable { case write, unconfirmed(UInt16) }
    var apple = 0.5
    var raw: UInt16 = 24
    let maximum: UInt16 = 100
    var calls: [(id: String, value: Double)] = []
    var failure: Failure?
    var screens = [IDs.builtIn, IDs.dell, IDs.projector]
    var names = [IDs.builtIn: "Built-in Retina Display", IDs.dell: "DELL U2720Q", IDs.projector: "Projector"]
    private var hold = false
    private var gate: CheckedContinuation<Void, Never>?

    func discover(methods: [String: BrightnessMethod]) async -> [BrightnessDisplay] {
        screens.enumerated().map { index, id in
            let bounds = CGRect(x: CGFloat(index) * 100, y: 0, width: 100, height: 100)
            let name = names[id] ?? id
            switch id {
            case IDs.builtIn:
                return BrightnessDisplay(id: id, displayID: 1, name: name, bounds: bounds, builtIn: true, value: apple)
            case IDs.dell:
                return BrightnessDisplay(id: id, displayID: 2, name: name, bounds: bounds, builtIn: false,
                                         value: BrightnessDDCScale.logical(raw: raw, maximum: maximum),
                                         hardwareMaximum: maximum, edidVendor: 0x10AC, edidProduct: 0x41B5)
            default:
                return BrightnessDisplay(id: id, displayID: 3, name: name, bounds: bounds, builtIn: false, value: nil)
            }
        }
    }

    func set(_ display: BrightnessDisplay, value: Double) async throws -> Double {
        if hold { await withCheckedContinuation { gate = $0 } }
        calls.append((display.id, value))
        if display.id == IDs.builtIn {
            if case .write = failure { throw BrightnessFailure.write }
            apple = value; return apple
        }
        let target = try BrightnessDDCScale.rawTarget(value, maximum: maximum)
        switch failure {
        case .write: throw BrightnessFailure.write
        case .unconfirmed(let other): raw = other
        case nil: raw = target
        }
        return try BrightnessDDCWriteTransaction.confirmLogical(target: target, maximum: maximum, reading: (raw, maximum))
    }

    func setFailure(_ failure: Failure?) { self.failure = failure }
    func setRaw(_ raw: UInt16) { self.raw = raw }
    func setApple(_ value: Double) { apple = value }
    func setScreens(_ ids: [String]) { screens = ids }
    func rename(_ id: String, _ name: String) { names[id] = name }
    func holdWrites() { hold = true }
    func releaseWrites() { hold = false; gate?.resume(); gate = nil }
    func reset() async {}
}

@MainActor
final class BrightnessAutomationTests: XCTestCase {

    private var provider: CLIProvider!
    private var osd: CLIOSD!
    private var blackout: CLIBlackout!
    private var model: DisplayBrightnessModel!
    private var config: Config!
    private var pointer: CGPoint? = CGPoint(x: 150, y: 50)   // over the Dell
    private var confirmWait: Duration = .seconds(5)

    override func setUp() async throws {
        provider = CLIProvider(); osd = CLIOSD(); blackout = CLIBlackout()
        model = DisplayBrightnessModel(provider: provider, osd: osd, blackout: blackout)
        config = Config(settings: Settings())
        config.settings.automationEnabled = true
        pointer = CGPoint(x: 150, y: 50)
        confirmWait = .seconds(5)
    }

    override func tearDown() async throws {
        model.stop()
    }

    private func service() -> BrightnessAutomation {
        BrightnessAutomation(model: model, config: { [unowned self] in self.config },
                             cursor: { [unowned self] in self.pointer },
                             confirmWait: confirmWait, pollInterval: .milliseconds(2))
    }

    private func handle(_ action: AutomationBrightnessRequest.Action, _ percent: Double? = nil,
                        display: String? = nil) async -> AutomationResponse {
        await service().handle(AutomationBrightnessRequest(action: action, percent: percent, display: display))
    }

    private func raw() async -> UInt16 { await provider.raw }

    private func blocks(_ response: AutomationResponse) -> [[String: String]] {
        response.stdout.components(separatedBy: "\n\n").map { block in
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                guard let colon = line.range(of: ": ") else { continue }
                fields[String(line[..<colon.lowerBound])] = String(line[colon.upperBound...])
            }
            return fields
        }
    }

    // MARK: access

    func testAutomationOffRefusesEveryActionWithTheCommandsRefusal() async {
        config.settings.automationEnabled = false
        for action in [AutomationBrightnessRequest.Action.list, .get, .set, .up, .down] {
            let response = await handle(action, action == .set ? 50 : nil)
            XCTAssertEqual(response.exitCode, AutomationExitCode.refused, "\(action)")
            XCTAssertEqual(response.stderr, AutomationRefusal.automationDisabled.message)
            XCTAssertEqual(response.stdout, "")
        }
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testNoDisplaysIsARefusal() async {
        await provider.setScreens([])
        let response = await handle(.get)
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertFalse(response.stderr.isEmpty)
    }

    func testBrightnessKeysOffStillWorks() async {
        config.settings.displays.keyboardEnabled = false
        let response = await handle(.set, 50)
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        let level = await raw()
        XCTAssertEqual(level, 24)
    }

    // MARK: list / get

    func testListShowsEveryDisplayWithIdMethodAvailabilityNitsAndDefaultTarget() async {
        let response = await handle(.list)
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(response.stderr, "")
        let entries = blocks(response)
        XCTAssertEqual(entries.map { $0["display"] }, ["Built-in Retina Display", "DELL U2720Q", "Projector"])
        XCTAssertEqual(entries.map { $0["id"] }, [IDs.builtIn, IDs.dell, IDs.projector])
        XCTAssertEqual(entries.map { $0["method"] }, ["native", "ddc", "none"])
        XCTAssertEqual(entries.map { $0["available"] }, ["yes", "yes", "no"])
        // raw24 is 1 + 99·√0.24 ≈ 49.5 → 49, the same integer the panel and OSD show.
        XCTAssertEqual(entries.map { $0["brightness"] }, ["50", "49", nil])
        // Dell U2720Q catalogue range 29…350, linear in raw: 29 + 321·24/100 ≈ 106 — as in the OSD.
        XCTAssertEqual(entries.map { $0["approxNits"] }, [nil, "106", nil])
        XCTAssertEqual(entries.map { $0["defaultTarget"] }, ["no", "yes", "no"])
        XCTAssertTrue(entries.allSatisfy { $0["status"] == nil && $0["confirmed"] == nil })
    }

    func testGetReadsTheDisplayUnderThePointerLikeTheKeys() async {
        pointer = CGPoint(x: 50, y: 50)
        let response = await handle(.get)
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(blocks(response).map { $0["id"] }, [IDs.builtIn])
        XCTAssertNil(blocks(response).first?["defaultTarget"])
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty, "get never writes")
        XCTAssertTrue(osd.shown.isEmpty, "get shows no OSD")
    }

    func testGetFollowsLinkedKeysOnlyWhenTheKeysAreOn() async {
        config.settings.displays.linkKeys = true
        config.settings.displays.keyboardEnabled = false
        var response = await handle(.get)
        XCTAssertEqual(blocks(response).map { $0["id"] }, [IDs.dell])
        config.settings.displays.keyboardEnabled = true
        response = await handle(.get)
        XCTAssertEqual(blocks(response).map { $0["id"] }, [IDs.dell, IDs.builtIn], "pointer display first, unsupported excluded")
    }

    func testDisplayByExactNameOrCaseInsensitiveID() async {
        var response = await handle(.get, display: "Built-in Retina Display")
        XCTAssertEqual(blocks(response).map { $0["id"] }, [IDs.builtIn])
        response = await handle(.get, display: IDs.builtIn.lowercased())
        XCTAssertEqual(blocks(response).map { $0["id"] }, [IDs.builtIn])
    }

    func testUnknownDisplayIsRefusedWithTheList() async {
        let response = await handle(.set, 30, display: "LG")
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertTrue(response.stderr.contains("LG"))
        XCTAssertTrue(response.stderr.contains("DELL U2720Q\t\(IDs.dell)\tyes"))
        XCTAssertTrue(response.stderr.contains("Projector\t\(IDs.projector)\tno"))
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testAmbiguousDisplayNameIsRefusedWithTheMatchingIDs() async {
        await provider.rename(IDs.builtIn, "DELL U2720Q")
        let response = await handle(.up, display: "DELL U2720Q")
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertTrue(response.stderr.contains(IDs.builtIn) && response.stderr.contains(IDs.dell))
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty)
    }

    func testUnsupportedDisplayIsRefusedNeverAnotherOne() async {
        var response = await handle(.up, display: "Projector")
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        XCTAssertTrue(response.stderr.contains("Projector"))
        pointer = CGPoint(x: 250, y: 50)   // over the projector
        response = await handle(.up)
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        pointer = CGPoint(x: 900, y: 900)  // off every display
        response = await handle(.get)
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        pointer = nil
        response = await handle(.get)
        XCTAssertEqual(response.exitCode, AutomationExitCode.refused)
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty, "the keys' rule: never change a different display instead")
    }

    // MARK: set / up / down

    func testSetUsesTheDDCScaleConfirmsAndShowsTheOSD() async throws {
        let response = await handle(.set, 75)
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        let level = await raw()
        XCTAssertEqual(level, 56, "75% → raw56 on the DDC scale")
        let entry = try XCTUnwrap(blocks(response).first)
        XCTAssertEqual(entry["status"], "applied")
        XCTAssertEqual(entry["id"], IDs.dell)
        XCTAssertEqual(entry["brightness"], "75")
        XCTAssertEqual(entry["confirmed"], "yes")
        XCTAssertEqual(entry["approxNits"], "209")   // 29 + 321·56/100
        XCTAssertNotNil(entry["message"])
        XCTAssertEqual(osd.shown.map(\.id), [IDs.dell])
        XCTAssertEqual(try XCTUnwrap(osd.shown.last?.value), BrightnessDDCScale.logical(raw: 56, maximum: 100)!, accuracy: 1e-12)
    }

    func testSetZeroIsTheBlackCoverWithoutAHardwareWriteAndUpLeavesItAtRawZero() async throws {
        var response = await handle(.set, 0)
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(blocks(response).first?["brightness"], "0")
        XCTAssertNil(blocks(response).first?["approxNits"])
        XCTAssertEqual(blackout.covered, [IDs.dell])
        var calls = await provider.calls
        XCTAssertTrue(calls.isEmpty, "0% never writes the hardware")

        response = await handle(.up, 0.1)
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertTrue(blackout.covered.isEmpty)
        let level = await raw()
        XCTAssertEqual(level, 0, "up from black is raw0, the darkest visible level")
        XCTAssertEqual(blocks(response).first?["brightness"], "1")
        calls = await provider.calls
        XCTAssertEqual(calls.count, 1)
    }

    func testEveryUpAndDownMovesTheConfirmedDDCLevelByAtLeastOneRaw() async {
        await provider.setRaw(10)
        var levels: [UInt16] = []
        for _ in 0..<4 {
            let response = await handle(.up, 0.1)   // far below one raw at this end of the scale
            XCTAssertEqual(response.exitCode, AutomationExitCode.success)
            levels.append(await raw())
        }
        XCTAssertEqual(levels, [11, 12, 13, 14])
        for _ in 0..<2 {
            _ = await handle(.down, 0.1)
            levels.append(await raw())
        }
        XCTAssertEqual(levels.suffix(2), [13, 12])
        _ = await handle(.up)   // the key step: 1/16 of the logical scale
        let level = await raw()
        XCTAssertGreaterThan(level, 12)
        XCTAssertEqual(level, try BrightnessDDCScale.rawTarget(BrightnessDDCScale.logical(raw: 12, maximum: 100)! + 1.0 / 16, maximum: 100))
    }

    func testUpAtTheTopIsAtLimit() async {
        await provider.setRaw(100)
        let response = await handle(.up)
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(blocks(response).first?["status"], "atLimit")
        XCTAssertEqual(blocks(response).first?["brightness"], "100")
        XCTAssertEqual(blocks(response).first?["confirmed"], "yes")
    }

    func testDownFromRawZeroGoesBlackThenIsAtLimit() async {
        await provider.setRaw(0)
        var response = await handle(.down)
        XCTAssertEqual(blocks(response).first?["status"], "applied")
        XCTAssertEqual(blackout.covered, [IDs.dell])
        response = await handle(.down)
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(blocks(response).first?["status"], "atLimit")
        XCTAssertEqual(blocks(response).first?["brightness"], "0")
        let calls = await provider.calls
        XCTAssertTrue(calls.isEmpty, "raw0 → black is the cover, not a write")
    }

    func testBuiltInDisplayUsesThePlainKeyStep() async throws {
        pointer = CGPoint(x: 50, y: 50)
        let response = await handle(.down)
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        let apple = await provider.apple
        XCTAssertEqual(apple, 0.5 - 1.0 / 16, accuracy: 1e-12)
        XCTAssertEqual(blocks(response).first?["method"], "native")
        XCTAssertEqual(blocks(response).first?["brightness"], "44")
    }

    func testDefaultTargetWithLinkedKeysChangesAllAndTheOSDShowsThePointerDisplay() async {
        config.settings.displays.keyboardEnabled = true
        config.settings.displays.linkKeys = true
        let response = await handle(.set, 50)
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(blocks(response).map { $0["id"] }, [IDs.dell, IDs.builtIn])
        let calls = await provider.calls
        XCTAssertEqual(Set(calls.map(\.id)), [IDs.dell, IDs.builtIn])
        XCTAssertEqual(osd.shown.map(\.id), [IDs.dell])
    }

    func testExplicitDisplayChangesOnlyThatDisplayEvenWithLinkedKeys() async {
        config.settings.displays.keyboardEnabled = true
        config.settings.displays.linkKeys = true
        let response = await handle(.set, 30, display: "Built-in Retina Display")
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(blocks(response).map { $0["id"] }, [IDs.builtIn])
        let calls = await provider.calls
        XCTAssertEqual(calls.map(\.id), [IDs.builtIn])
        XCTAssertEqual(osd.shown.map(\.id), [IDs.builtIn])
    }

    func testAFailedWriteIsExitOne() async {
        await provider.setFailure(.write)
        let response = await handle(.set, 40)
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed)
        XCTAssertEqual(blocks(response).first?["status"], "failed")
        XCTAssertEqual(blocks(response).first?["confirmed"], "no")
        XCTAssertEqual(blocks(response).first?["brightness"], "49", "the last confirmed value")
        XCTAssertTrue(osd.shown.isEmpty)
    }

    func testAnUnconfirmedWriteReportsWhatTheDisplayReadsBack() async {
        await provider.setFailure(.unconfirmed(80))
        let response = await handle(.set, 40)
        XCTAssertEqual(response.exitCode, AutomationExitCode.failed)
        XCTAssertEqual(blocks(response).first?["confirmed"], "no")
        XCTAssertEqual(blocks(response).first?["brightness"], "90")   // 1 + 99·√0.8 ≈ 89.5
    }

    func testNoReadbackWithinTheWaitIsTimedOut() async {
        confirmWait = .milliseconds(60)
        await provider.holdWrites()
        let response = await handle(.set, 70)
        XCTAssertEqual(response.exitCode, AutomationExitCode.timedOut)
        XCTAssertEqual(blocks(response).first?["status"], "timedOut")
        XCTAssertEqual(blocks(response).first?["confirmed"], "no")
        await provider.releaseWrites()
    }

    // MARK: router

    func testRouterSendsBrightnessToTheBrightnessService() async {
        let manager = ProcessManager(runner: FakeCommandRunner(), notifier: FakeNotifier(), appController: FakeAppController(),
                                     reaper: FakeDaemonReaper(), portInspector: FakePortInspector(),
                                     hostMonitoringEnabled: { false })
        let automation = AutomationService(manager: manager, config: { [unowned self] in self.config })
        let router = AutomationRequestRouter(service: automation, brightness: service())
        let response = await router.handle(AutomationRequest(operation: .brightness,
                                                             brightness: AutomationBrightnessRequest(action: .get)))
        XCTAssertEqual(response.exitCode, AutomationExitCode.success)
        XCTAssertEqual(blocks(response).map { $0["id"] }, [IDs.dell])
        let incomplete = await router.handle(AutomationRequest(operation: .brightness))
        XCTAssertEqual(incomplete.exitCode, AutomationExitCode.usage)
    }

    // MARK: serialization

    func testEntryTextIsKeyValueLinesInAFixedOrder() {
        let entry = BrightnessAutomationEntry(status: .applied, name: "DELL\nU2720Q", id: IDs.dell, method: "ddc",
                                              available: true, percent: 52, nits: 94, defaultTarget: nil,
                                              confirmed: true, message: "ok")
        XCTAssertEqual(entry.text, """
            status: applied
            display: DELL U2720Q
            id: \(IDs.dell)
            method: ddc
            available: yes
            brightness: 52
            approxNits: 94
            confirmed: yes
            message: ok
            """)
    }
}
