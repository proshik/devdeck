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
                              isDevelopmentBuild: isDevelopmentBuild,
                              bundleID: Bundle.main.bundleIdentifier ?? "DevDeck") { request, url, wait in
            AutomationSocketClient.send(request, socketURL: url, receiveTimeout: wait)
        }
        FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
        FileHandle.standardError.write(Data(outcome.stderr.utf8))
        return outcome.code
    }

    static func execute(_ arguments: [String], currentDirectory: String, isDevelopmentBuild: Bool,
                        bundleID: String, send: Sender) -> Outcome {
        switch parse(arguments, currentDirectory: currentDirectory, isDevelopmentBuild: isDevelopmentBuild) {
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

    static func parse(_ arguments: [String], currentDirectory: String,
                      isDevelopmentBuild: Bool) -> Result<Invocation, UsageError> {
        // The data directory first, and in plain English: in a development build the language
        // preference is read through `AppRuntime`, which refuses a bad `--dev-data-directory`
        // outright — so no localized text may be produced before the flag is known to be valid.
        var args = arguments
        var dataDirectory: String?
        if let index = args.firstIndex(of: "--dev-data-directory") {
            guard args.indices.contains(index + 1) else {
                return .failure(UsageError(message: plainUsage("Option --dev-data-directory needs a value.")))
            }
            dataDirectory = args[index + 1]
            args.removeSubrange(index...(index + 1))
        }
        if let problem = dataDirectoryProblem(dataDirectory, isDevelopmentBuild: isDevelopmentBuild) {
            return .failure(UsageError(message: plainUsage(problem)))
        }

        if args.contains("--help") || args.contains("-h") || args.first == "help" { return .success(.help) }
        guard let first = args.first else { return usage(L10n.automationUsageNoOperation) }
        guard let operation = AutomationOperation(rawValue: first) else {
            return usage(L10n.automationUsageUnknownOperation(first))
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

    /// A development build must name its data directory, so its command line can never reach the
    /// installed DevDeck; a release build has no such flag.
    private static func dataDirectoryProblem(_ directory: String?, isDevelopmentBuild: Bool) -> String? {
        guard isDevelopmentBuild else {
            return directory == nil ? nil : "--dev-data-directory is only accepted by development builds."
        }
        guard let directory else {
            return "This is a development build: pass --dev-data-directory PATH, the same as the running development DevDeck."
        }
        guard directory.hasPrefix("/") else { return "--dev-data-directory requires an absolute path." }
        let given = URL(fileURLWithPath: directory, isDirectory: true).resolvingSymlinksInPath().standardizedFileURL
        let installed = AutomationEndpoint.installedDataDirectory.resolvingSymlinksInPath().standardizedFileURL
        guard given.path != installed.path else {
            return "--dev-data-directory must not be the installed DevDeck's data directory."
        }
        return nil
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
