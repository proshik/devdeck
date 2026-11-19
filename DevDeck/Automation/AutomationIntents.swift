import AppIntents
import Foundation

// Shortcuts actions for saved commands and chains (stage 8). Thin on purpose: every decision is in
// `AutomationService`; these only resolve the app's service, pass parameters and return the report.
// Titles are static App Intents metadata (English); results and refusals follow the DevDeck language.
// No `AppShortcutsProvider`: the actions show up in Shortcuts under DevDeck without one.
// App Intents metadata needs literals: the timeout default and range below repeat
// `AutomationLimits` (a test keeps them equal); the service clamps whatever arrives anyway.

/// Where the intents find the running app's service. Set by `AppDelegate` once the config is loaded.
@MainActor
enum AutomationHost {
    static var service: AutomationService?

    /// When Shortcuts launches DevDeck to run an action, the action may arrive before
    /// `applicationDidFinishLaunching` — wait for it instead of failing at once.
    static func ready() async throws -> AutomationService {
        let deadline = ContinuousClock.now + .seconds(AutomationLimits.readinessWaitSeconds)
        while true {
            if let service { return service }
            guard ContinuousClock.now < deadline else { throw AutomationRefusal.notReady }
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}

/// Shortcuts shows this text for a refused action (and `shortcuts run` prints it).
extension AutomationRefusal: CustomLocalizedStringResourceConvertible {
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

// MARK: entities

struct DevDeckCommandEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "DevDeck Command"
    static let defaultQuery = DevDeckCommandQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct DevDeckCommandQuery: EntityStringQuery {
    /// Any id a saved shortcut holds resolves, even a deleted or no longer allowed one, so that
    /// `perform` runs and refuses with a clear message.
    func entities(for identifiers: [UUID]) async throws -> [DevDeckCommandEntity] {
        let service = try await AutomationHost.ready()
        return await MainActor.run {
            identifiers.map { DevDeckCommandEntity(id: $0, name: service.commandName($0) ?? L10n.automationUnknownItem) }
        }
    }

    func suggestedEntities() async throws -> [DevDeckCommandEntity] {
        let service = try await AutomationHost.ready()
        return await MainActor.run { service.availableCommands().map { DevDeckCommandEntity(id: $0.id, name: $0.name) } }
    }

    /// Text input (`shortcuts run … --input-path`) resolves by name or id among the allowed ones.
    func entities(matching string: String) async throws -> [DevDeckCommandEntity] {
        try await suggestedEntities().filter { Self.matches($0.id, $0.name, string) }
    }

    static func matches(_ id: UUID, _ name: String, _ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return id.uuidString.caseInsensitiveCompare(query) == .orderedSame
            || name.localizedCaseInsensitiveContains(query)
    }
}

struct DevDeckChainEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "DevDeck Chain"
    static let defaultQuery = DevDeckChainQuery()

    let id: UUID
    let name: String

    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct DevDeckChainQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [DevDeckChainEntity] {
        let service = try await AutomationHost.ready()
        return await MainActor.run {
            identifiers.map { DevDeckChainEntity(id: $0, name: service.chainName($0) ?? L10n.automationUnknownItem) }
        }
    }

    func suggestedEntities() async throws -> [DevDeckChainEntity] {
        let service = try await AutomationHost.ready()
        return await MainActor.run { service.availableChains().map { DevDeckChainEntity(id: $0.id, name: $0.name) } }
    }

    func entities(matching string: String) async throws -> [DevDeckChainEntity] {
        try await suggestedEntities().filter { DevDeckCommandQuery.matches($0.id, $0.name, string) }
    }
}

// MARK: command actions

struct RunDevDeckCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Run DevDeck Command"
    static let description = IntentDescription(
        "Runs a saved DevDeck command and waits for the result: a one-shot command until it finishes or the timeout passes (it keeps running then), a background command until it is up. Returns key: value lines and the last lines of output.")
    static let openAppWhenRun = false

    @Parameter(title: "Command")
    var command: DevDeckCommandEntity

    @Parameter(title: "Directory",
               description: "Working directory for a command that asks for one each run; an absolute path.")
    var directory: String?

    @Parameter(title: "Timeout (seconds)", description: "How long to wait for the result, 1…3600.",
               default: 300, inclusiveRange: (1, 3600))
    var timeoutSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$command)") {
            \.$directory
            \.$timeoutSeconds
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let service = try await AutomationHost.ready()
        let report = try await service.runCommand(command.id, directory: directory,
                                                  timeout: AutomationLimits.timeout(seconds: timeoutSeconds))
        return .result(value: report.text)
    }
}

struct StopDevDeckCommandIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop DevDeck Command"
    static let description = IntentDescription("Stops a running DevDeck command and reports its state.")
    static let openAppWhenRun = false

    @Parameter(title: "Command")
    var command: DevDeckCommandEntity

    static var parameterSummary: some ParameterSummary { Summary("Stop \(\.$command)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let service = try await AutomationHost.ready()
        return .result(value: try await service.stopCommand(command.id).text)
    }
}

struct GetDevDeckCommandStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get DevDeck Command Status"
    static let description = IntentDescription("Reports the state, exit code and last lines of output of a DevDeck command.")
    static let openAppWhenRun = false

    @Parameter(title: "Command")
    var command: DevDeckCommandEntity

    static var parameterSummary: some ParameterSummary { Summary("Get status of \(\.$command)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let service = try await AutomationHost.ready()
        return .result(value: try await MainActor.run { try service.commandStatus(command.id).text })
    }
}

// MARK: chain actions

struct RunDevDeckChainIntent: AppIntent {
    static let title: LocalizedStringResource = "Run DevDeck Chain"
    static let description = IntentDescription(
        "Runs a saved DevDeck chain and waits until it finishes or the timeout passes (it keeps running then). Returns key: value lines with the failed step.")
    static let openAppWhenRun = false

    @Parameter(title: "Chain")
    var chain: DevDeckChainEntity

    @Parameter(title: "Timeout (seconds)", description: "How long to wait for the result, 1…3600.",
               default: 300, inclusiveRange: (1, 3600))
    var timeoutSeconds: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Run \(\.$chain)") {
            \.$timeoutSeconds
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let service = try await AutomationHost.ready()
        let report = try await service.runChain(chain.id, timeout: AutomationLimits.timeout(seconds: timeoutSeconds))
        return .result(value: report.text)
    }
}

struct StopDevDeckChainIntent: AppIntent {
    static let title: LocalizedStringResource = "Stop DevDeck Chain"
    static let description = IntentDescription("Stops a running DevDeck chain and reports its state.")
    static let openAppWhenRun = false

    @Parameter(title: "Chain")
    var chain: DevDeckChainEntity

    static var parameterSummary: some ParameterSummary { Summary("Stop \(\.$chain)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let service = try await AutomationHost.ready()
        return .result(value: try await service.stopChain(chain.id).text)
    }
}

struct GetDevDeckChainStatusIntent: AppIntent {
    static let title: LocalizedStringResource = "Get DevDeck Chain Status"
    static let description = IntentDescription("Reports the state and the current or failed step of a DevDeck chain.")
    static let openAppWhenRun = false

    @Parameter(title: "Chain")
    var chain: DevDeckChainEntity

    static var parameterSummary: some ParameterSummary { Summary("Get status of \(\.$chain)") }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let service = try await AutomationHost.ready()
        return .result(value: try await MainActor.run { try service.chainStatus(chain.id).text })
    }
}
