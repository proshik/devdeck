import Foundation

/// `DevDeck automation awake …`. No keep-awake logic of its own: `AwakeModel` starts the same
/// synthetic daemon the popover button does — the administrator prompt, the privileged helper,
/// the battery and thermal cutoffs and the restore are all its. This type checks access, passes
/// the duration, waits for the outcome and words the answer.
@MainActor
final class AwakeAutomation {
    private let model: AwakeModel
    private let config: () -> Config
    private let startWait: Duration
    private let stopWait: Duration
    private let pollInterval: Duration
    private let now: () -> Date

    init(model: AwakeModel, config: @escaping () -> Config,
         startWait: Duration = .seconds(AutomationLimits.awakeStartWaitSeconds),
         stopWait: Duration = .seconds(AutomationLimits.awakeStopWaitSeconds),
         pollInterval: Duration = .milliseconds(100),
         now: @escaping () -> Date = Date.init) {
        self.model = model
        self.config = config
        self.startWait = startWait
        self.stopWait = stopWait
        self.pollInterval = pollInterval
        self.now = now
    }

    func handle(_ request: AutomationAwakeRequest) async -> AutomationResponse {
        if let problem = Self.invalid(request) { return AutomationFields.usage(problem) }
        do {
            let settings = config().settings
            guard settings.automationEnabled else { throw AutomationRefusal.automationDisabled }
            guard settings.automationAwakeEnabled else { throw AutomationRefusal.awakeAutomationDisabled }
            // The app's own loop does this every 2 s (not in an isolated development launch).
            model.refresh()
            switch request.action {
            case .status: return AutomationFields.response([block()])
            case .on: return try await on(seconds: request.seconds)
            case .off: return try await off()
            }
        } catch {
            return AutomationFields.refusal(error)
        }
    }

    private static func invalid(_ request: AutomationAwakeRequest) -> String? {
        guard let seconds = request.seconds else { return nil }
        guard request.action == .on else { return L10n.automationUsageForOnlyOn }
        guard seconds == 0 || (1...AwakeModel.maxSeconds).contains(seconds) else {
            return L10n.automationUsageBadDuration(String(seconds))
        }
        return nil
    }

    private func on(seconds: Int?) async throws -> AutomationResponse {
        if model.isBusy {
            if model.recovering { throw AutomationRefusal.awakeRecovering }
            if model.stopping { return AutomationFields.response([block()], code: AutomationExitCode.failed) }
            // Already on or waiting for authorization: not started twice, the running session is kept.
            return AutomationFields.response([block(message: model.isActive ? L10n.automationAwakeAlreadyOn
                                                                            : L10n.awakeStarting)])
        }
        model.start(seconds: seconds)
        guard model.isBusy else {
            if model.thermalStop { throw AutomationRefusal.awakeThermal }
            return AutomationFields.response([block()], code: AutomationExitCode.failed)
        }
        let deadline = ContinuousClock.now + startWait
        while model.isBusy, !model.isActive, ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
        }
        if model.isActive { return AutomationFields.response([block()]) }
        if model.isBusy {
            return AutomationFields.response([block(message: L10n.automationAwakeAuthorizationPending(
                Int(startWait.components.seconds)))], code: AutomationExitCode.timedOut)
        }
        // Cancelled authorization leaves the daemon idle; a refusing helper leaves it failed.
        let message = model.state == .idle && model.error == nil ? L10n.automationAwakeCancelled : nil
        return AutomationFields.response([block(message: message)], code: AutomationExitCode.failed)
    }

    private func off() async throws -> AutomationResponse {
        guard model.isBusy else { return AutomationFields.response([block()]) }
        if model.recovering { throw AutomationRefusal.awakeRecovering }
        model.stop()
        let deadline = ContinuousClock.now + stopWait
        while model.isBusy, ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
        }
        if model.isBusy {
            return AutomationFields.response([block(message: L10n.awakeStopping)], code: AutomationExitCode.timedOut)
        }
        model.refresh()
        if model.recoveryAvailable || model.error != nil {
            return AutomationFields.response([block()], code: AutomationExitCode.failed)
        }
        return AutomationFields.response([block(message: L10n.automationAwakeStopped)])
    }

    private func block(message override: String? = nil) -> AutomationFields {
        var fields = AutomationFields()
        let status: String
        let message: String
        if model.isBusy && model.recovering {
            status = "recovering"; message = L10n.automationAwakeRecovering
        } else if model.isBusy && model.stopping {
            status = "stopping"; message = L10n.awakeStopping
        } else if model.isActive {
            status = "on"
            if let remaining = model.remainingSeconds(now: now()) {
                message = L10n.automationAwakeOnFor(Self.duration(remaining))
            } else {
                message = L10n.automationAwakeOnIndefinitely
            }
        } else if model.isBusy {
            status = "starting"; message = L10n.awakeStarting
        } else if case .failed = model.state {
            status = "failed"; message = L10n.awakeError
        } else {
            status = "off"
            message = model.error.map { _ in L10n.awakeRestoreFailed }
                ?? (model.thermalStop ? L10n.awakeThermalStop : L10n.automationAwakeOff)
        }
        fields.add("status", status)
        fields.add("state", AutomationService.describe(model.state))
        if model.isBusy && !model.recovering, let seconds = model.sessionSeconds {
            fields.add("durationSeconds", seconds)
        } else if !model.isBusy {
            fields.add("durationSeconds", model.durationSeconds)
        }
        fields.add("remainingSeconds", model.remainingSeconds(now: now()))
        if model.recoveryAvailable { fields.add("recoveryAvailable", yes: true) }
        if model.thermalStop { fields.add("thermalStop", yes: true) }
        fields.add("message", override ?? message)
        if status == "failed" || model.error != nil {
            fields.addOutput(AutomationFields.tail(model.manager.logs[AwakeHelper.daemonID]))
        }
        return fields
    }

    /// `1h 05m`, `12m 30s`, `45s` — for the message; the number itself is `remainingSeconds`.
    static func duration(_ seconds: Int) -> String {
        let h = seconds / 3600, m = seconds % 3600 / 60, s = seconds % 60
        if h > 0 { return String(format: "%dh %02dm", h, m) }
        if m > 0 { return String(format: "%dm %02ds", m, s) }
        return "\(s)s"
    }
}
