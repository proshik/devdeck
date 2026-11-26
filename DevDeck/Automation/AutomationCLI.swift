import Foundation

/// `DevDeck automation …` — the command-line client of a running DevDeck (stage 8, iteration 2).
///
/// The same executable as the app: `DevDeckMain` hands the arguments over before `NSApplication`
/// exists, so this process never shows a window, a Dock icon or a menu bar item, and it never
/// starts DevDeck. Everything a request does is decided app-side by `AutomationService`.
enum AutomationCLI {
    static let verb = "automation"

    enum Invocation: Equatable {
        case help
        /// `dataDirectory` is the `--dev-data-directory` of a development build, nil for a release.
        case request(AutomationRequest, dataDirectory: String?)
    }

    struct UsageError: Error, Equatable {
        let message: String
    }

    struct Outcome: Equatable {
        var code: Int32
        var stdout: String
        var stderr: String
    }

    typealias Sender = (AutomationRequest, URL, TimeInterval) -> Result<AutomationResponse, AutomationSocketClient.Failure>

    static var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    /// Extra wait of the client beyond the run's own timeout (port check, a sudo prompt, the reply).
    static let runReplyMargin: TimeInterval = 120
    /// Wait for stop (up to `stopWaitSeconds` app-side), status and list.
    static let shortReplyWait: TimeInterval = 60

    // MARK: entry

    /// Called by `DevDeckMain` with the arguments after `automation`. Returns the exit code.
    static func main(_ arguments: [String]) -> Int32 {
        let outcome = execute(arguments, currentDirectory: FileManager.default.currentDirectoryPath,
                              isDevelopmentBuild: isDevelopmentBuild, bundleInfo: Bundle.main.infoDictionary ?? [:],
                              bundleID: Bundle.main.bundleIdentifier ?? "DevDeck") { request, url, wait in
            AutomationSocketClient.send(request, socketURL: url, receiveTimeout: wait)
        }
        FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        FileHandle.standardError.write(Data(outcome.stderr.utf8))
        return outcome.code
    }

    static func execute(_ arguments: [String], currentDirectory: String, isDevelopmentBuild: Bool,
                        bundleInfo: [String: Any], bundleID: String, send: Sender) -> Outcome {
        switch parse(arguments, currentDirectory: currentDirectory, isDevelopmentBuild: isDevelopmentBuild,
                     bundleInfo: bundleInfo) {
        case .failure(let error):
            return Outcome(code: AutomationExitCode.usage, stdout: "", stderr: error.message + "\n")
        case .success(.help):
            return Outcome(code: AutomationExitCode.success, stdout: L10n.automationHelpText + "\n", stderr: "")
        case .success(.request(let request, let dataDirectory)):
            let directory = dataDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? AutomationEndpoint.installedDataDirectory
            let socket = AutomationEndpoint.socketURL(bundleID: bundleID, dataDirectory: directory)
            let wait = request.operation == .run
                ? TimeInterval(AutomationLimits.timeout(seconds: request.timeoutSeconds).components.seconds) + runReplyMargin
                : shortReplyWait
            switch send(request, socket, wait) {
            case .success(let response):
                return Outcome(code: response.exitCode, stdout: line(response.stdout), stderr: line(response.stderr))
            case .failure(.notRunning):
                return Outcome(code: AutomationExitCode.appNotRunning, stdout: "", stderr: L10n.automationAppNotRunning + "\n")
            case .failure(.communication(let detail)):
                return Outcome(code: AutomationExitCode.communication, stdout: "",
                               stderr: L10n.automationCommunicationFailed(detail) + "\n")
            }
        }
    }

    // MARK: parsing

    /// `bundleInfo` is the executable's Info.plist: a packaged development build carries its data
    /// directory there, so the bare binary reaches the same isolated app the bare launch starts.
    static func parse(_ arguments: [String], currentDirectory: String, isDevelopmentBuild: Bool,
                      bundleInfo: [String: Any] = [:]) -> Result<Invocation, UsageError> {
        // The data directory first, and in plain English: in a development build the language
        // preference is read through `AppRuntime`, which refuses a bad data directory outright —
        // so no localized text may be produced before it is known to be valid.
        var args = arguments
        let flag = AppRuntime.developmentDirectoryArgument
        let dataDirectory: String?
        if isDevelopmentBuild {
            switch AppRuntime.resolveDevelopmentDirectory(arguments: args, info: bundleInfo,
                                                          installed: AutomationEndpoint.installedDataDirectory) {
            case .none:
                return .failure(UsageError(message: plainUsage(
                    "This is a development build without a data directory: pass \(flag) PATH, the same as the running development DevDeck.")))
            case .invalid(let reason):
                return .failure(UsageError(message: plainUsage(reason)))
            case .directory(let url):
                dataDirectory = url.path
            }
        } else {
            if args.contains(flag) {
                return .failure(UsageError(message: plainUsage("\(flag) is only accepted by development builds.")))
            }
            dataDirectory = nil
        }
        if let index = args.firstIndex(of: flag) { args.removeSubrange(index...min(index + 1, args.count - 1)) }

        if args.contains("--help") || args.contains("-h") || args.first == "help" { return .success(.help) }
        guard let first = args.first else { return usage(L10n.automationUsageNoOperation) }
        guard let operation = AutomationOperation(rawValue: first) else {
            return usage(L10n.automationUsageUnknownOperation(first))
        }
        if operation == .brightness {
            return parseBrightness(Array(args.dropFirst())).map { .request($0, dataDirectory: dataDirectory) }
        }
        if operation == .proxy {
            return parseProxy(Array(args.dropFirst())).map { .request($0, dataDirectory: dataDirectory) }
        }
        if operation == .awake {
            return parseAwake(Array(args.dropFirst())).map { .request($0, dataDirectory: dataDirectory) }
        }

        var positional: [String] = []
        var directory: String?
        var timeout: Int?
        var rest = args.dropFirst()[...]
        while let arg = rest.popFirst() {
            switch arg {
            case "--directory", "--timeout":
                guard let value = rest.popFirst(), !value.isEmpty else {
                    return usage(L10n.automationUsageMissingValue(arg))
                }
                if arg == "--timeout" {
                    guard let seconds = Int(value),
                          (AutomationLimits.minTimeoutSeconds...AutomationLimits.maxTimeoutSeconds).contains(seconds) else {
                        return usage(L10n.automationUsageBadTimeout(value))
                    }
                    timeout = seconds
                } else {
                    directory = absolute(value, from: currentDirectory)
                }
            default:
                if arg.hasPrefix("--") { return usage(L10n.automationUsageUnknownOption(arg)) }
                positional.append(arg)
            }
        }

        if operation == .list {
            if let extra = positional.first { return usage(L10n.automationUsageExtraArgument(extra)) }
            if directory != nil { return usage(L10n.automationUsageOptionNotApplicable("--directory")) }
            if timeout != nil { return usage(L10n.automationUsageOptionNotApplicable("--timeout")) }
            return .success(.request(AutomationRequest(operation: .list), dataDirectory: dataDirectory))
        }
        guard let kindName = positional.first else { return usage(L10n.automationUsageMissingTarget) }
        guard let kind = AutomationReport.Kind(rawValue: kindName) else {
            return usage(L10n.automationUsageUnknownKind(kindName))
        }
        guard positional.count >= 2, !positional[1].trimmingCharacters(in: .whitespaces).isEmpty else {
            return usage(L10n.automationUsageMissingTarget)
        }
        if positional.count > 2 { return usage(L10n.automationUsageExtraArgument(positional[2])) }
        if directory != nil, !(operation == .run && kind == .command) {
            return usage(L10n.automationUsageOptionNotApplicable("--directory"))
        }
        if timeout != nil, operation != .run { return usage(L10n.automationUsageOptionNotApplicable("--timeout")) }

        return .success(.request(AutomationRequest(operation: operation, kind: kind, target: positional[1],
                                                   directory: directory, timeoutSeconds: timeout),
                                 dataDirectory: dataDirectory))
    }

    /// `brightness list | get | set <0…100> | up|down [step]`, each but list with `--display <name|id>`.
    private static func parseBrightness(_ args: [String]) -> Result<AutomationRequest, UsageError> {
        func failure(_ problem: String) -> Result<AutomationRequest, UsageError> {
            .failure(UsageError(message: L10n.automationUsage(problem)))
        }
        guard let first = args.first else { return failure(L10n.automationUsageNoBrightnessAction) }
        guard let action = AutomationBrightnessRequest.Action(rawValue: first) else {
            return failure(L10n.automationUsageUnknownBrightnessAction(first))
        }
        var positional: [String] = []
        var display: String?
        var rest = args.dropFirst()[...]
        while let arg = rest.popFirst() {
            switch arg {
            case "--display":
                guard let value = rest.popFirst(), !value.trimmingCharacters(in: .whitespaces).isEmpty else {
                    return failure(L10n.automationUsageMissingValue(arg))
                }
                display = value
            case "--directory", "--timeout":
                return failure(L10n.automationUsageOptionNotApplicable(arg))
            default:
                if arg.hasPrefix("--") { return failure(L10n.automationUsageUnknownOption(arg)) }
                positional.append(arg)
            }
        }
        if action == .list, display != nil { return failure(L10n.automationUsageBrightnessListDisplay) }

        var percent: Double?
        switch action {
        case .list, .get:
            if let extra = positional.first { return failure(L10n.automationUsageExtraArgument(extra)) }
        case .set:
            guard let value = positional.first else { return failure(L10n.automationUsageMissingBrightness) }
            guard let number = Double(value), number.isFinite, (0...100).contains(number) else {
                return failure(L10n.automationUsageBadBrightness(value))
            }
            percent = number
        case .up, .down:
            if let value = positional.first {
                guard let number = Double(value), number.isFinite, number > 0, number <= 100 else {
                    return failure(L10n.automationUsageBadBrightnessStep(value))
                }
                percent = number
            }
        }
        if positional.count > 1 { return failure(L10n.automationUsageExtraArgument(positional[1])) }
        return .success(AutomationRequest(operation: .brightness,
                                          brightness: AutomationBrightnessRequest(action: action, percent: percent,
                                                                                  display: display)))
    }

    /// `proxy list | status | check | use <name|UUID|none> | share on|off|status | share set [options]`.
    private static func parseProxy(_ args: [String]) -> Result<AutomationRequest, UsageError> {
        func failure(_ problem: String) -> Result<AutomationRequest, UsageError> {
            .failure(UsageError(message: L10n.automationUsage(problem)))
        }
        func request(_ body: AutomationProxyRequest) -> Result<AutomationRequest, UsageError> {
            .success(AutomationRequest(operation: .proxy, proxy: body))
        }
        guard let first = args.first else { return failure(L10n.automationUsageNoProxyAction) }
        var rest = Array(args.dropFirst())
        switch first {
        case "list", "status", "check":
            if let extra = rest.first { return failure(extra.hasPrefix("--") ? L10n.automationUsageUnknownOption(extra)
                                                                              : L10n.automationUsageExtraArgument(extra)) }
            let action: AutomationProxyRequest.Action = first == "list" ? .list : first == "status" ? .status : .check
            return request(AutomationProxyRequest(action: action))
        case "use":
            if let option = rest.first(where: { $0.hasPrefix("--") }) { return failure(L10n.automationUsageUnknownOption(option)) }
            guard let target = rest.first, !target.trimmingCharacters(in: .whitespaces).isEmpty else {
                return failure(L10n.automationUsageMissingProxy)
            }
            if rest.count > 1 { return failure(L10n.automationUsageExtraArgument(rest[1])) }
            return request(AutomationProxyRequest(action: .use, target: target))
        case "share":
            guard let sub = rest.first else { return failure(L10n.automationUsageNoShareAction) }
            rest.removeFirst()
            switch sub {
            case "on", "off", "status":
                if let extra = rest.first {
                    return failure(extra.hasPrefix("--") ? L10n.automationUsageUnknownOption(extra)
                                                         : L10n.automationUsageExtraArgument(extra))
                }
                let action: AutomationProxyRequest.Action = sub == "on" ? .shareOn : sub == "off" ? .shareOff : .shareStatus
                return request(AutomationProxyRequest(action: action))
            case "set":
                var body = AutomationProxyRequest(action: .shareSet)
                var queue = rest[...]
                while let arg = queue.popFirst() {
                    guard ["--port", "--engine", "--service-name", "--auth", "--username"].contains(arg) else {
                        return failure(arg.hasPrefix("--") ? L10n.automationUsageUnknownOption(arg)
                                                           : L10n.automationUsageExtraArgument(arg))
                    }
                    // An empty service name or username is a value: the host name, no username.
                    guard let value = queue.popFirst() else { return failure(L10n.automationUsageMissingValue(arg)) }
                    switch arg {
                    case "--port":
                        guard let port = Int(value), AutomationProxyRequest.validPorts.contains(port) else {
                            return failure(L10n.automationUsageBadPort(value))
                        }
                        body.port = port
                    case "--engine":
                        guard let engine = ProxyEngine.allCases.first(where: { $0.rawValue.lowercased() == value.lowercased() }) else {
                            return failure(L10n.automationUsageBadEngine(value))
                        }
                        body.engine = engine
                    case "--auth":
                        guard value == "on" || value == "off" else { return failure(L10n.automationUsageBadAuth(value)) }
                        body.auth = value == "on"
                    case "--service-name":
                        body.serviceName = value
                    default:
                        body.username = value
                    }
                }
                guard body.setsShareField else { return failure(L10n.automationUsageNoShareField) }
                return request(body)
            default:
                return failure(L10n.automationUsageUnknownShareAction(sub))
            }
        default:
            return failure(L10n.automationUsageUnknownProxyAction(first))
        }
    }

    /// `awake on [--for DURATION] | off | status`.
    private static func parseAwake(_ args: [String]) -> Result<AutomationRequest, UsageError> {
        func failure(_ problem: String) -> Result<AutomationRequest, UsageError> {
            .failure(UsageError(message: L10n.automationUsage(problem)))
        }
        guard let first = args.first else { return failure(L10n.automationUsageNoAwakeAction) }
        guard let action = AutomationAwakeRequest.Action(rawValue: first) else {
            return failure(L10n.automationUsageUnknownAwakeAction(first))
        }
        var seconds: Int?
        var rest = args.dropFirst()[...]
        while let arg = rest.popFirst() {
            guard arg == "--for" else {
                return failure(arg.hasPrefix("--") ? L10n.automationUsageUnknownOption(arg) : L10n.automationUsageExtraArgument(arg))
            }
            guard action == .on else { return failure(L10n.automationUsageForOnlyOn) }
            guard let value = rest.popFirst(), !value.isEmpty else { return failure(L10n.automationUsageMissingValue(arg)) }
            guard let parsed = awakeDuration(value) else { return failure(L10n.automationUsageBadDuration(value)) }
            seconds = parsed
        }
        return .success(AutomationRequest(operation: .awake, awake: AutomationAwakeRequest(action: action, seconds: seconds)))
    }

    /// `0` (indefinitely), whole seconds, or `<n>h`, `<n>m`, `<n>s` from the largest unit down,
    /// combined (`1h30m`); 1 s…`AwakeModel.maxSeconds`. nil for anything else.
    static func awakeDuration(_ text: String) -> Int? {
        let value = text.lowercased()
        if let seconds = Int(value), value.allSatisfy(\.isASCII) {
            return seconds == 0 || (1...AwakeModel.maxSeconds).contains(seconds) ? seconds : nil
        }
        var total = 0
        var digits = ""
        var lastUnit = Int.max
        for character in value {
            if character.isASCII, character.isNumber { digits.append(character); continue }
            let unit: Int
            switch character {
            case "h": unit = 3600
            case "m": unit = 60
            case "s": unit = 1
            default: return nil
            }
            // Each unit once and from the largest down; `30m2h` is a typo, not 2.5 hours.
            guard let amount = Int(digits), unit < lastUnit else { return nil }
            guard amount <= AwakeModel.maxSeconds else { return nil }
            total += amount * unit
            lastUnit = unit
            digits = ""
        }
        guard digits.isEmpty, lastUnit != Int.max else { return nil }
        // Only a bare `0` means indefinitely: `0m` reads as a mistake.
        return (1...AwakeModel.maxSeconds).contains(total) ? total : nil
    }

    private static func absolute(_ path: String, from currentDirectory: String) -> String {
        var path = (path as NSString).expandingTildeInPath
        if !path.hasPrefix("/") { path = (currentDirectory as NSString).appendingPathComponent(path) }
        return (path as NSString).standardizingPath
    }

    private static func usage(_ problem: String) -> Result<Invocation, UsageError> {
        .failure(UsageError(message: L10n.automationUsage(problem)))
    }

    private static func plainUsage(_ problem: String) -> String {
        problem + "\nRun `DevDeck automation help` for usage."
    }

    private static func line(_ text: String) -> String { text.isEmpty ? "" : text + "\n" }
}
