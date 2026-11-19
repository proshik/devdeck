import Foundation

/// The result of a Shortcuts request, rendered as `key: value` lines with fixed English keys so a
/// person can read it and an agent can parse it; only `message` follows the DevDeck language.
struct AutomationReport: Equatable, Sendable {
    enum Status: String, Sendable {
        case succeeded, failed, timedOut, running, stopped, alreadyRunning, openedInTerminal, notRunning, idle
    }

    enum Kind: String, Sendable {
        case command, chain
    }

    var status: Status
    var kind: Kind
    var name: String
    var id: UUID
    /// The `ProcessManager` state name (`idle`, `running`, `daemonRunning`, `succeeded`, `failed`, `stopped`).
    var state: String
    var exitCode: Int32? = nil
    /// 1-based, chains only.
    var failedStep: Int? = nil
    var failedStepName: String? = nil
    var currentStep: Int? = nil
    var currentStepName: String? = nil
    /// The directory a `promptForDirectory` copy ran in.
    var directory: String? = nil
    var timeoutSeconds: Int? = nil
    var port: Int? = nil
    var portOccupant: PortOccupant? = nil
    var message: String
    var output: [String] = []

    var text: String {
        var lines: [String] = []
        func add(_ key: String, _ value: CustomStringConvertible?) {
            guard let value else { return }
            lines.append("\(key): " + value.description.replacingOccurrences(of: "\n", with: " "))
        }
        add("status", status.rawValue)
        add("kind", kind.rawValue)
        add("name", name)
        add("id", id.uuidString)
        add("state", state)
        add("exitCode", exitCode)
        add("failedStep", failedStep)
        add("failedStepName", failedStepName)
        add("currentStep", currentStep)
        add("currentStepName", currentStepName)
        add("directory", directory)
        add("timeoutSeconds", timeoutSeconds)
        add("port", port)
        add("portOwner", portOccupant.map { "\($0.processName) (PID \($0.pid))" })
        add("message", message)
        if !output.isEmpty {
            lines.append("output (last \(output.count) lines):")
            lines.append(contentsOf: output)
        }
        return lines.joined(separator: "\n")
    }
}
