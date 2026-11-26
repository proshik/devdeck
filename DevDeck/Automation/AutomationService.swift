import Foundation

/// Limits of a Shortcuts request. The intents expose the timeout as a parameter; the service
/// clamps whatever arrives (a hand-built shortcut can pass anything).
enum AutomationLimits {
    /// How long "Run" waits for a one-shot command or a chain by default.
    static let defaultTimeoutSeconds = 300
    static let minTimeoutSeconds = 1
    /// Upper bound of the wait: one hour. Longer work belongs to a daemon or a terminal command.
    static let maxTimeoutSeconds = 3600
    /// Lines of output returned with a result — the tail of the run's ring buffer.
    static let outputLines = 30
    /// A single returned line is cut to this many characters (minified JSON, progress bars).
    static let maxLineLength = 1000
    /// How long "Stop" waits for the run to reach a neutral state.
    static let stopWaitSeconds = 10
    /// How long an intent waits for the app to finish launching when Shortcuts started it.
    static let readinessWaitSeconds = 15
    /// How long `DevDeck automation brightness set|up|down` waits for the display's readback.
    static let brightnessWaitSeconds = 10
    /// How long `proxy use <remote>` and `proxy share on|set` wait for their daemons to come up.
    static let proxyStartWaitSeconds = 15
    /// How long `proxy check` waits for the probe (one curl with a 5 s limit).
    static let proxyCheckWaitSeconds = 15
    /// How long `awake on` waits: the administrator prompt needs a person.
    static let awakeStartWaitSeconds = 45
    /// How long `awake off` waits for the helper to restore sleep (it polls its lease every 2 s).
    static let awakeStopWaitSeconds = 15

    static func timeout(seconds: Int?) -> Duration {
        .seconds(min(max(seconds ?? defaultTimeoutSeconds, minTimeoutSeconds), maxTimeoutSeconds))
    }
}

/// Why a request was not carried out. Thrown out of the intent, so Shortcuts shows the message
/// and `shortcuts run` exits non-zero. A command that ran and failed is a result, not a refusal.
enum AutomationRefusal: Error, Equatable, LocalizedError {
    case automationDisabled
    case commandNotFound(UUID)
    case chainNotFound(UUID)
    case commandNotAllowed(String)
    case chainNotAllowed(String)
    case directoryRequired(String)
    case directoryMissing(String)
    case directoryNotAccepted(String)
    case portOccupied(port: Int, process: String, pid: Int32)
    case proxyUnavailable(String)
    case sudoDaemonUnsupported(String)
    case notReady
    /// Command line: no command/chain of this kind is called that (and it is no UUID of one).
    case unknownName(AutomationReport.Kind, String)
    /// Command line: several share the name — the caller must pick one by UUID.
    case ambiguousName(AutomationReport.Kind, String, [UUID])
    /// `brightness`: no display is discovered (yet). Display lists are `name<TAB>id<TAB>available`.
    case noBrightnessDisplays
    /// `brightness` without `--display`: the pointer is over no display.
    case noPointerDisplay([String])
    case displayUnsupported(String, [String])
    case unknownDisplay(String, [String])
    case ambiguousDisplay(String, [String])
    /// `proxy …` / `awake …` while their own switch in Settings → Automation is off.
    case proxyAutomationDisabled
    case awakeAutomationDisabled
    /// `proxy use`: lists are `type<TAB>name<TAB>id`; `discoveryOn` explains an empty LAN half.
    case unknownProxy(String, [String], discoveryOn: Bool)
    case ambiguousProxy(String, [String])
    case proxyCredentialsMissing(String)
    case remoteTunnelMissing(String)
    /// `proxy check` found nothing to probe; the reason is the popover's own wording.
    case proxyCheckUnavailable(String)
    case gostMissing
    /// `--auth on` / `share on` with auth: the Keychain has no share password, or no username is set.
    case sharePasswordMissing
    case shareUsernameMissing
    /// `awake on` under serious/critical thermal pressure.
    case awakeThermal
    /// `awake on|off` while "Restore sleep" runs: it cannot be interrupted.
    case awakeRecovering

    var message: String {
        switch self {
        case .automationDisabled: L10n.automationDisabledMessage
        case .commandNotFound(let id): L10n.automationCommandNotFound(id)
        case .chainNotFound(let id): L10n.automationChainNotFound(id)
        case .commandNotAllowed(let name): L10n.automationCommandNotAllowed(name)
        case .chainNotAllowed(let name): L10n.automationChainNotAllowed(name)
        case .directoryRequired(let name): L10n.automationDirectoryRequired(name)
        case .directoryMissing(let path): L10n.automationDirectoryMissing(path)
        case .directoryNotAccepted(let name): L10n.automationDirectoryNotAccepted(name)
        case .portOccupied(let port, let process, let pid): L10n.automationPortOccupied(port, process, pid)
        case .proxyUnavailable(let name): L10n.automationProxyUnavailable(name)
        case .sudoDaemonUnsupported(let name): L10n.automationSudoDaemon(name)
        case .notReady: L10n.automationNotReady
        case .unknownName(let kind, let name): L10n.automationUnknownName(kind == .chain, name)
        case .ambiguousName(let kind, let name, let ids): L10n.automationAmbiguousName(kind == .chain, name, ids)
        case .noBrightnessDisplays: L10n.automationNoBrightnessDisplays
        case .noPointerDisplay(let displays): L10n.automationNoPointerDisplay(displays)
        case .displayUnsupported(let name, let displays): L10n.automationDisplayUnsupported(name, displays)
        case .unknownDisplay(let query, let displays): L10n.automationUnknownDisplay(query, displays)
        case .ambiguousDisplay(let query, let displays): L10n.automationAmbiguousDisplay(query, displays)
        case .proxyAutomationDisabled: L10n.automationProxyDisabled
        case .awakeAutomationDisabled: L10n.automationAwakeDisabled
        case .unknownProxy(let query, let proxies, let discoveryOn):
            L10n.automationUnknownProxy(query, proxies, discoveryOn: discoveryOn)
        case .ambiguousProxy(let query, let proxies): L10n.automationAmbiguousProxy(query, proxies)
        case .proxyCredentialsMissing(let name): L10n.automationProxyCredentialsMissing(name)
        case .remoteTunnelMissing(let name): L10n.automationRemoteTunnelMissing(name)
        case .proxyCheckUnavailable(let reason): reason
        case .gostMissing: L10n.gostNotFound
        case .sharePasswordMissing: L10n.automationSharePasswordMissing
        case .shareUsernameMissing: L10n.automationShareUsernameMissing
        case .awakeThermal: L10n.awakeThermalStop
        case .awakeRecovering: L10n.automationAwakeRecovering
        }
    }

    var errorDescription: String? { message }
}

/// Whether a path names an existing directory — behind a protocol so tests touch no file system.
protocol DirectoryProbe: Sendable {
    func isDirectory(atPath path: String) -> Bool
}

struct LiveDirectoryProbe: DirectoryProbe {
    func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}

/// Run, stop and read saved commands and chains on behalf of Shortcuts. All the logic of stage 8
/// lives here; the App Intents only translate parameters and results.
///
/// Runs go through the same `ProcessManager` entry points as the popover (`run(_:)`,
/// `run(_:commands:)`, `stop`, `stopChain`), so its checks apply unchanged: the port pre-check,
/// proxy routing that fails loudly, the sudo-daemon ban and `appsToQuit`. What differs from the
/// UI: an occupied port is a refusal carrying the owner instead of the "Kill & start" panel, and
/// a directory comes as a parameter instead of an open panel.
@MainActor
final class AutomationService {
    private let manager: ProcessManager
    private let config: () -> Config
    private let portInspector: any PortInspector
    private let directories: any DirectoryProbe
    private let pollInterval: Duration
    private let stopWait: Duration
    /// Commands this service is starting right now: between the request and the run showing up
    /// in `ProcessManager` (port pre-check, `appsToQuit`) the state still shows the previous run,
    /// and a second request must not slip through as "not running".
    private var launching: Set<UUID> = []

    init(manager: ProcessManager, config: @escaping () -> Config,
         portInspector: any PortInspector = LivePortInspector(),
         directories: any DirectoryProbe = LiveDirectoryProbe(),
         pollInterval: Duration = .milliseconds(50),
         stopWait: Duration = .seconds(AutomationLimits.stopWaitSeconds)) {
        self.manager = manager
        self.config = config
        self.portInspector = portInspector
        self.directories = directories
        self.pollInterval = pollInterval
        self.stopWait = stopWait
    }

    // MARK: what Shortcuts may see

    /// Commands offered in the Shortcuts picker: only the allowed ones, and none while automation is off.
    func availableCommands() -> [Command] {
        let config = config()
        guard config.settings.automationEnabled else { return [] }
        return config.commands.filter(\.allowAutomation)
    }

    func availableChains() -> [Chain] {
        let config = config()
        guard config.settings.automationEnabled else { return [] }
        return config.chains.filter(\.allowAutomation)
    }

    /// Current name for an id a saved shortcut refers to, whatever its permission: the refusal then
    /// comes from `perform` with a clear message instead of a silently unresolved parameter.
    func commandName(_ id: UUID) -> String? { config().commands.first { $0.id == id }?.name }
    func chainName(_ id: UUID) -> String? { config().chains.first { $0.id == id }?.name }

    // MARK: what the command line may see

    struct ListedItem: Equatable {
        let kind: AutomationReport.Kind
        let id: UUID
        let name: String
    }

    /// `DevDeck automation list`: the allowed commands, then the allowed chains. Unlike the
    /// Shortcuts picker, which just shows nothing, a disabled switch is a refusal here.
    func listing() throws -> [ListedItem] {
        guard config().settings.automationEnabled else { throw AutomationRefusal.automationDisabled }
        return availableCommands().map { ListedItem(kind: .command, id: $0.id, name: $0.name) }
            + availableChains().map { ListedItem(kind: .chain, id: $0.id, name: $0.name) }
    }

    /// The id the command line means: a UUID (any case) or the exact name among all items of the
    /// kind. Permission is checked afterwards by the operation itself, so a disallowed command is
    /// refused as "not allowed" rather than reported as unknown.
    func resolve(_ kind: AutomationReport.Kind, _ query: String) throws -> UUID {
        let config = config()
        guard config.settings.automationEnabled else { throw AutomationRefusal.automationDisabled }
        let items: [(id: UUID, name: String)] = kind == .command
            ? config.commands.map { ($0.id, $0.name) } : config.chains.map { ($0.id, $0.name) }
        if let id = UUID(uuidString: query.trimmingCharacters(in: .whitespaces)) {
            return id   // an unknown id is refused by the operation, with the id in the message
        }
        let matches = items.filter { $0.name == query }
        switch matches.count {
        case 0: throw AutomationRefusal.unknownName(kind, query)
        case 1: return matches[0].id
        default: throw AutomationRefusal.ambiguousName(kind, query, matches.map(\.id))
        }
    }

    // MARK: commands

    func runCommand(_ id: UUID, directory: String?, timeout: Duration) async throws -> AutomationReport {
        let stored = try allowedCommand(id)
        if isCommandActive(id) { return statusReport(stored, status: .alreadyRunning) }
        let command = try bindDirectory(stored, directory)
        guard !(command.needsSudo && command.isDaemon) else { throw AutomationRefusal.sudoDaemonUnsupported(command.name) }

        let deadline = ContinuousClock.now + timeout
        launching.insert(id)
        defer { launching.remove(id) }
        if command.isDaemon, let port = command.port, let occupant = await occupant(ofPort: port) {
            DiagnosticLog.shared.log("Automation: port \(port) is occupied by \(occupant.processName) (PID \(occupant.pid)) — “\(command.name)” not started", level: .warn)
            throw AutomationRefusal.portOccupied(port: port, process: occupant.processName, pid: occupant.pid)
        }
        // The lsof await let the world move: a UI click may have started it meanwhile.
        if StatusIndicator.forCommand(manager.states[id]).isStop { return statusReport(stored, status: .alreadyRunning) }

        DiagnosticLog.shared.log("Automation: run “\(command.name)” [\(id.uuidString.prefix(8))]")
        let launchesBefore = manager.launchCounts[id] ?? 0
        manager.run(command)
        return try await awaitCommand(command, launchesBefore: launchesBefore, deadline: deadline, timeout: timeout)
    }

    func stopCommand(_ id: UUID) async throws -> AutomationReport {
        let command = try allowedCommand(id)
        guard StatusIndicator.forCommand(manager.states[id]).isStop else {
            return report(command, status: .notRunning, message: L10n.automationNotRunning(command.name))
        }
        DiagnosticLog.shared.log("Automation: stop “\(command.name)” [\(id.uuidString.prefix(8))]")
        manager.stop(id)
        try await wait(until: { !StatusIndicator.forCommand(self.manager.states[id]).isStop },
                       deadline: ContinuousClock.now + stopWait)
        if StatusIndicator.forCommand(manager.states[id]).isStop {
            return report(command, status: .running, message: L10n.automationStopPending(command.name))
        }
        return statusReport(command, status: manager.states[id] == .idle || manager.states[id] == nil ? .stopped : nil)
    }

    func commandStatus(_ id: UUID) throws -> AutomationReport {
        statusReport(try allowedCommand(id))
    }

    // MARK: chains

    func runChain(_ id: UUID, timeout: Duration) async throws -> AutomationReport {
        let chain = try allowedChain(id)
        if StatusIndicator.forChain(manager.chainStates[id]).isStop { return chainReport(chain, status: .alreadyRunning) }
        let commands = config().commandsByID
        let deadline = ContinuousClock.now + timeout
        DiagnosticLog.shared.log("Automation: run chain “\(chain.name)” [\(id.uuidString.prefix(8))]")
        manager.run(chain, commands: commands)   // sets `.running` synchronously
        if chain.openInTerminal {
            return chainReport(chain, status: .openedInTerminal, message: L10n.automationOpenedInTerminal(chain.name))
        }
        try await wait(until: { !StatusIndicator.forChain(self.manager.chainStates[id]).isStop }, deadline: deadline)
        if StatusIndicator.forChain(manager.chainStates[id]).isStop {
            var report = chainReport(chain, status: .timedOut,
                                     message: L10n.automationTimedOut(chain.name, Self.seconds(timeout)))
            report.timeoutSeconds = Self.seconds(timeout)
            return report
        }
        return chainReport(chain)
    }

    func stopChain(_ id: UUID) async throws -> AutomationReport {
        let chain = try allowedChain(id)
        guard StatusIndicator.forChain(manager.chainStates[id]).isStop else {
            return chainReport(chain, status: .notRunning, message: L10n.automationNotRunning(chain.name))
        }
        DiagnosticLog.shared.log("Automation: stop chain “\(chain.name)” [\(id.uuidString.prefix(8))]")
        manager.stopChain(id)
        try await wait(until: { !StatusIndicator.forChain(self.manager.chainStates[id]).isStop },
                       deadline: ContinuousClock.now + stopWait)
        if StatusIndicator.forChain(manager.chainStates[id]).isStop {
            return chainReport(chain, status: .running, message: L10n.automationStopPending(chain.name))
        }
        return chainReport(chain)
    }

    func chainStatus(_ id: UUID) throws -> AutomationReport {
        chainReport(try allowedChain(id))
    }

    // MARK: access

    private func allowedCommand(_ id: UUID) throws -> Command {
        let config = config()
        guard config.settings.automationEnabled else { throw AutomationRefusal.automationDisabled }
        guard let command = config.commands.first(where: { $0.id == id }) else { throw AutomationRefusal.commandNotFound(id) }
        guard command.allowAutomation else { throw AutomationRefusal.commandNotAllowed(command.name) }
        return command
    }

    private func allowedChain(_ id: UUID) throws -> Chain {
        let config = config()
        guard config.settings.automationEnabled else { throw AutomationRefusal.automationDisabled }
        guard let chain = config.chains.first(where: { $0.id == id }) else { throw AutomationRefusal.chainNotFound(id) }
        guard chain.allowAutomation else { throw AutomationRefusal.chainNotAllowed(chain.name) }
        return chain
    }

    private func isCommandActive(_ id: UUID) -> Bool {
        launching.contains(id) || StatusIndicator.forCommand(manager.states[id]).isStop
    }

    /// The popover asks a `promptForDirectory` command where to run and launches a copy bound to
    /// the answer; here the answer is the parameter. Other commands keep their stored directory.
    private func bindDirectory(_ command: Command, _ directory: String?) throws -> Command {
        let path = directory.map { ($0.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath }
            .flatMap { $0.isEmpty ? nil : $0 }
        guard command.promptForDirectory else {
            if path != nil { throw AutomationRefusal.directoryNotAccepted(command.name) }
            return command
        }
        guard let path else { throw AutomationRefusal.directoryRequired(command.name) }
        guard path.hasPrefix("/"), directories.isDirectory(atPath: path) else {
            throw AutomationRefusal.directoryMissing(path)
        }
        return command.withWorkingDirectory(path)
    }

    // MARK: waiting

    /// Follow the run this request issued. `launchCounts` moves once `startRun` begins — before
    /// that the state is the previous run's leftover (a deferred launch behind `appsToQuit` or the
    /// port pre-check), so it is not read.
    private func awaitCommand(_ command: Command, launchesBefore: Int, deadline: ContinuousClock.Instant,
                              timeout: Duration) async throws -> AutomationReport {
        let id = command.id
        while true {
            if (manager.launchCounts[id] ?? 0) > launchesBefore {
                switch manager.states[id] {
                case .running?:
                    if command.openInTerminal {
                        return report(command, status: .openedInTerminal,
                                      message: L10n.automationOpenedInTerminal(command.name))
                    }
                case .daemonRunning?, .succeeded?, .idle?, nil:
                    return statusReport(command, status: manager.states[id] == .idle || manager.states[id] == nil ? .stopped : nil)
                case .failed(let code)?:
                    if code == ProcessManager.proxyUnavailableCode, command.routeThroughProxy {
                        throw AutomationRefusal.proxyUnavailable(command.name)
                    }
                    var result = statusReport(command)
                    if command.isDaemon, let port = command.port, let occupant = await occupant(ofPort: port) {
                        result.port = port
                        result.portOccupant = occupant
                    }
                    return result
                }
            } else if let conflict = manager.portConflicts[id] {
                // The manager's own pre-check lost a race with another listener: same refusal,
                // and no kill panel left behind by an automated request.
                manager.dismissPortConflict(id)
                throw AutomationRefusal.portOccupied(port: conflict.port, process: conflict.occupant.processName,
                                                     pid: conflict.occupant.pid)
            }
            if ContinuousClock.now >= deadline {
                var result = report(command, status: .timedOut,
                                    message: L10n.automationTimedOut(command.name, Self.seconds(timeout)))
                result.timeoutSeconds = Self.seconds(timeout)
                return result
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    private func wait(until done: () -> Bool, deadline: ContinuousClock.Instant) async throws {
        while !done(), ContinuousClock.now < deadline {
            try await Task.sleep(for: pollInterval)
        }
    }

    private func occupant(ofPort port: Int) async -> PortOccupant? {
        let inspector = portInspector
        return await Task.detached(priority: .userInitiated) { inspector.occupant(ofPort: port) }.value
    }

    // MARK: reports

    /// A report from the command's current state; `status` overrides the state-derived one.
    private func statusReport(_ command: Command, status override: AutomationReport.Status? = nil) -> AutomationReport {
        let state = manager.states[command.id]
        var result: AutomationReport
        switch state {
        case nil, .idle?:
            result = report(command, status: .idle, message: L10n.automationNotRunning(command.name))
        case .running?:
            result = report(command, status: .running, message: L10n.automationRunning(command.name))
        case .daemonRunning?:
            result = report(command, status: .running, message: L10n.automationDaemonUp(command.name))
        case .succeeded?:
            result = report(command, status: .succeeded, message: L10n.automationSucceeded(command.name))
            result.exitCode = 0
        case .failed(let code)?:
            result = report(command, status: .failed, message: command.isDaemon
                            ? L10n.automationDaemonFailed(command.name, code) : L10n.automationFailed(command.name, code))
            result.exitCode = code
        }
        if let conflict = manager.portConflicts[command.id] {
            result.port = conflict.port
            result.portOccupant = conflict.occupant
        }
        if let override {
            result.status = override
            switch override {
            case .alreadyRunning: result.message = L10n.automationAlreadyRunning(command.name)
            case .stopped: result.message = L10n.automationStopped(command.name)
            default: break
            }
        }
        return result
    }

    private func report(_ command: Command, status: AutomationReport.Status, message: String) -> AutomationReport {
        AutomationReport(status: status, kind: .command, name: command.name, id: command.id,
                         state: Self.describe(manager.states[command.id]),
                         directory: command.promptForDirectory ? command.workingDirectory : nil,
                         message: message, output: tail(of: command.id))
    }

    private func chainReport(_ chain: Chain, status override: AutomationReport.Status? = nil,
                             message overrideMessage: String? = nil) -> AutomationReport {
        let state = manager.chainStates[chain.id]
        var result = AutomationReport(status: .idle, kind: .chain, name: chain.name, id: chain.id,
                                      state: Self.describe(state), message: L10n.automationNotRunning(chain.name))
        let stepName: (Int) -> String = { index in
            guard chain.commandIDs.indices.contains(index) else { return L10n.deletedCommand }
            return self.config().commandsByID[chain.commandIDs[index]]?.name ?? L10n.deletedCommand
        }
        let stepOutput: (Int) -> [String] = { index in
            chain.commandIDs.indices.contains(index) ? self.tail(of: chain.commandIDs[index]) : []
        }
        switch state {
        case nil, .idle?:
            break
        case .running(let index)?:
            result.status = .running
            result.message = L10n.automationRunning(chain.name)
            if !chain.openInTerminal {
                result.currentStep = index + 1
                result.currentStepName = stepName(index)
                result.output = stepOutput(index)
            }
        case .succeeded?:
            result.status = .succeeded
            result.message = L10n.automationSucceeded(chain.name)
            result.exitCode = 0
            result.output = chain.openInTerminal ? tail(of: chain.id) : stepOutput(chain.commandIDs.count - 1)
        case .failed(let index, let code)?:
            result.status = .failed
            result.exitCode = code
            if chain.openInTerminal {
                result.message = L10n.automationFailed(chain.name, code)
                result.output = tail(of: chain.id)
            } else {
                result.failedStep = index + 1
                result.failedStepName = stepName(index)
                result.message = L10n.automationChainFailed(chain.name, index + 1, stepName(index), code)
                result.output = stepOutput(index)
            }
        case .stopped?:
            result.status = .stopped
            result.message = L10n.automationStopped(chain.name)
        }
        if let override {
            result.status = override
            if override == .alreadyRunning { result.message = L10n.automationAlreadyRunning(chain.name) }
        }
        if let overrideMessage { result.message = overrideMessage }
        return result
    }

    private func tail(of id: UUID) -> [String] {
        (manager.logs[id]?.elements ?? []).suffix(AutomationLimits.outputLines).map {
            $0.text.count > AutomationLimits.maxLineLength
                ? String($0.text.prefix(AutomationLimits.maxLineLength)) + "…" : $0.text
        }
    }

    private static func seconds(_ duration: Duration) -> Int { Int(duration.components.seconds) }

    static func describe(_ state: ProcessManager.RunState?) -> String {
        switch state {
        case nil, .idle?: "idle"
        case .running?: "running"
        case .daemonRunning?: "daemonRunning"
        case .succeeded?: "succeeded"
        case .failed?: "failed"
        }
    }

    private static func describe(_ state: ProcessManager.ChainState?) -> String {
        switch state {
        case nil, .idle?: "idle"
        case .running?: "running"
        case .succeeded?: "succeeded"
        case .failed?: "failed"
        case .stopped?: "stopped"
        }
    }
}
