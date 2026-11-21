import CoreGraphics
import Foundation

/// One display in a `DevDeck automation brightness` answer, rendered as `key: value` lines with
/// fixed English keys; only `message` follows the DevDeck language.
struct BrightnessAutomationEntry: Equatable, Sendable {
    enum Status: String, Sendable {
        case applied, atLimit, failed, timedOut
    }

    /// Set/up/down only.
    var status: Status?
    var name: String
    var id: String
    /// `ddc`, `native`, `software`, or `none` for a display without brightness control.
    var method: String
    var available: Bool
    /// Confirmed level, whole percent; nil without control.
    var percent: Int?
    /// The “≈N nits” of the OSD and the panel; nil when they show the percentage only.
    var nits: Int?
    /// List only: the display the brightness keys would change right now.
    var defaultTarget: Bool?
    /// Set/up/down only: the display read back the requested level.
    var confirmed: Bool?
    var message: String?

    var text: String {
        var lines: [String] = []
        func add(_ key: String, _ value: CustomStringConvertible?) {
            guard let value else { return }
            lines.append("\(key): " + value.description.replacingOccurrences(of: "\n", with: " "))
        }
        func yesNo(_ value: Bool?) -> String? { value.map { $0 ? "yes" : "no" } }
        add("status", status?.rawValue)
        add("display", name)
        add("id", id)
        add("method", method)
        add("available", yesNo(available))
        add("brightness", percent)
        add("approxNits", nits)
        add("defaultTarget", yesNo(defaultTarget))
        add("confirmed", yesNo(confirmed))
        add("message", message)
        return lines.joined(separator: "\n")
    }
}

/// `DevDeck automation brightness …` (AUTO-01, «Яркость из CLI»). No brightness logic of its own:
/// every change is a key-style request of `DisplayBrightnessModel` — the DDC scale, the black
/// cover at 0%, readback confirmation and the OSD are the keys' and the slider's. This type only
/// picks the display, waits for the readback and words the answer.
@MainActor
final class BrightnessAutomation {
    private let model: DisplayBrightnessModel
    private let config: () -> Config
    /// Pointer location in the CGEvent (upper-left) space, as the key handler reads it.
    private let cursor: () -> CGPoint?
    private let confirmWait: Duration
    private let pollInterval: Duration

    init(model: DisplayBrightnessModel, config: @escaping () -> Config,
         cursor: @escaping () -> CGPoint? = { CGEvent(source: nil)?.location },
         confirmWait: Duration = .seconds(AutomationLimits.brightnessWaitSeconds),
         pollInterval: Duration = .milliseconds(20)) {
        self.model = model
        self.config = config
        self.cursor = cursor
        self.confirmWait = confirmWait
        self.pollInterval = pollInterval
    }

    func handle(_ request: AutomationBrightnessRequest) async -> AutomationResponse {
        // The client validates too; a hand-made socket request must not black a screen out.
        if let problem = Self.invalid(request) {
            return AutomationResponse(exitCode: AutomationExitCode.usage, stdout: "", stderr: problem)
        }
        do {
            guard config().settings.automationEnabled else { throw AutomationRefusal.automationDisabled }
            if model.displays.isEmpty { await model.refresh() }
            guard !model.displays.isEmpty else { throw AutomationRefusal.noBrightnessDisplays }
            if request.action == .list { return answer(list()) }
            let (target, linked) = try targets(request.display)
            let entries: [BrightnessAutomationEntry]
            switch request.action {
            case .list: preconditionFailure("handled above")
            case .get:
                entries = group(target, linked: linked).map { entry(for: $0) }
            case .set:
                let value = (request.percent ?? 0) / 100
                entries = try await change(target, linked: linked, edge: nil) {
                    model.request(id: target.id, value: value, fromKeys: true, linked: linked, track: true)
                }
            case .up, .down:
                let up = request.action == .up
                let step = (request.percent.map { $0 / 100 } ?? DisplayBrightnessModel.keyStep) * (up ? 1 : -1)
                entries = try await change(target, linked: linked, edge: up ? 1 : 0) {
                    model.step(id: target.id, by: step, linked: linked, track: true)
                }
            }
            return answer(entries)
        } catch let refusal as AutomationRefusal {
            return AutomationResponse(exitCode: AutomationExitCode.refused, stdout: "", stderr: refusal.message)
        } catch {
            return AutomationResponse(exitCode: AutomationExitCode.communication, stdout: "",
                                      stderr: error.localizedDescription)
        }
    }

    private static func invalid(_ request: AutomationBrightnessRequest) -> String? {
        switch request.action {
        case .list, .get:
            return nil
        case .set:
            guard let percent = request.percent, percent.isFinite, (0...100).contains(percent) else {
                return L10n.automationUsageBadBrightness(request.percent.map { "\($0)" } ?? "")
            }
        case .up, .down:
            if let step = request.percent, !(step.isFinite && step > 0 && step <= 100) {
                return L10n.automationUsageBadBrightnessStep("\(step)")
            }
        }
        return nil
    }

    // MARK: choosing the display

    /// The display named by `--display`, alone; otherwise the keys' target — the display under
    /// the pointer, with every linked display when the keys are on and linked.
    private func targets(_ query: String?) throws -> (BrightnessDisplay, linked: Bool) {
        let displays = model.displays
        guard let query else {
            guard let point = cursor(), let target = displays.first(where: { $0.bounds.contains(point) }) else {
                throw AutomationRefusal.noPointerDisplay(listing(displays))
            }
            guard target.value != nil else { throw AutomationRefusal.displayUnsupported(target.name, listing(displays)) }
            let keys = config().settings.displays
            return (target, keys.keyboardEnabled && keys.linkKeys)
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matches = displays.filter { $0.id.caseInsensitiveCompare(trimmed) == .orderedSame }
            + displays.filter { $0.name == query && $0.id.caseInsensitiveCompare(trimmed) != .orderedSame }
        switch matches.count {
        case 0: throw AutomationRefusal.unknownDisplay(query, listing(displays))
        case 1:
            guard matches[0].value != nil else {
                throw AutomationRefusal.displayUnsupported(matches[0].name, listing(displays))
            }
            return (matches[0], false)
        default: throw AutomationRefusal.ambiguousDisplay(query, listing(matches))
        }
    }

    /// The displays a request on `target` reaches — the same filter the model applies.
    private func group(_ target: BrightnessDisplay, linked: Bool) -> [BrightnessDisplay] {
        guard linked else { return [target] }
        return [target] + model.displays.filter { $0.id != target.id && $0.value != nil }
    }

    private func listing(_ displays: [BrightnessDisplay]) -> [String] {
        displays.map { "\(Self.oneLine($0.name))\t\($0.id)\t\($0.value != nil ? "yes" : "no")" }
    }

    // MARK: changing

    /// Queues one key-style request and waits until every display it reached has answered.
    /// `edge` is the end of the scale an up/down moves towards: no change there is `atLimit`.
    private func change(_ target: BrightnessDisplay, linked: Bool, edge: Double?,
                        _ send: () -> BrightnessTicket?) async throws -> [BrightnessAutomationEntry] {
        let reached = group(target, linked: linked)
        let before = Dictionary(uniqueKeysWithValues: reached.map { ($0.id, $0.value) })
        guard let ticket = send() else { throw AutomationRefusal.displayUnsupported(target.name, listing(model.displays)) }
        defer { model.release(ticket) }
        let deadline = ContinuousClock.now + confirmWait
        while !model.isSettled(ticket) {
            guard ContinuousClock.now < deadline else {
                return reached.map { display in
                    entry(for: current(display), status: .timedOut, confirmed: false,
                          message: L10n.automationBrightnessTimedOut(display.name, AutomationLimits.brightnessWaitSeconds))
                }
            }
            try await Task.sleep(for: pollInterval)
        }
        let outcomes = model.outcomes(ticket)
        return reached.map { display in
            let now = current(display)
            switch outcomes[display.id] {
            case .confirmed:
                let previous = before[display.id] ?? nil
                let unchanged = edge != nil && now.value == previous && now.value == edge
                return entry(for: now, status: unchanged ? .atLimit : .applied, confirmed: true,
                             message: unchanged ? L10n.automationBrightnessAtLimit(now.name, level(now))
                                                : L10n.automationBrightnessApplied(now.name, level(now)))
            case .unconfirmed:
                return entry(for: now, status: .failed, confirmed: false,
                             message: L10n.automationBrightnessUnconfirmed(now.name, level(now)))
            case .failed:
                return entry(for: now, status: .failed, confirmed: false,
                             message: model.errors[display.id] ?? L10n.brightnessWriteFailed)
            case nil:
                return entry(for: now, status: .failed, confirmed: false,
                             message: L10n.automationBrightnessReplaced(now.name))
            }
        }
    }

    /// The display as the model knows it now; the snapshot if it has gone.
    private func current(_ display: BrightnessDisplay) -> BrightnessDisplay {
        model.displays.first { $0.id == display.id } ?? display
    }

    private func level(_ display: BrightnessDisplay) -> String {
        BrightnessLevelText.text(value: display.value ?? 0, nits: model.nits(for: display))
    }

    // MARK: answer

    private func list() -> [BrightnessAutomationEntry] {
        let keyTarget = cursor().flatMap { point in model.displays.first { $0.bounds.contains(point) && $0.value != nil } }
        return model.displays.map { display in
            var entry = entry(for: display)
            entry.defaultTarget = display.id == keyTarget?.id
            return entry
        }
    }

    private func entry(for display: BrightnessDisplay, status: BrightnessAutomationEntry.Status? = nil,
                       confirmed: Bool? = nil, message: String? = nil) -> BrightnessAutomationEntry {
        BrightnessAutomationEntry(status: status, name: display.name, id: display.id, method: Self.method(display),
                                  available: display.value != nil,
                                  percent: display.value.map { Int(($0 * 100).rounded()) },
                                  nits: model.nits(for: display).map { Int($0.rounded()) },
                                  confirmed: confirmed, message: message)
    }

    static func method(_ display: BrightnessDisplay) -> String {
        guard display.value != nil else { return "none" }
        switch display.method {
        case .software: return "software"
        case .hardware: return display.hardwareMaximum != nil ? "ddc" : "native"
        }
    }

    private func answer(_ entries: [BrightnessAutomationEntry]) -> AutomationResponse {
        let statuses = entries.compactMap(\.status)
        let code = statuses.contains(.timedOut) ? AutomationExitCode.timedOut
            : statuses.contains(.failed) ? AutomationExitCode.failed : AutomationExitCode.success
        return AutomationResponse(exitCode: code, stdout: entries.map(\.text).joined(separator: "\n\n"), stderr: "")
    }

    private static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    }
}
