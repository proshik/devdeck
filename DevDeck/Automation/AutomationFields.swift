import Foundation

/// One block of a `DevDeck automation proxy|awake` answer: `key: value` lines with fixed English
/// keys, the same shape `status` and `brightness` print. Blocks are separated by an empty line.
struct AutomationFields: Equatable {
    private(set) var lines: [String] = []

    mutating func add(_ key: String, _ value: CustomStringConvertible?) {
        guard let value else { return }
        lines.append("\(key): " + value.description.replacingOccurrences(of: "\n", with: " "))
    }

    mutating func add(_ key: String, yes value: Bool?) {
        add(key, value.map { $0 ? "yes" : "no" })
    }

    /// The tail of a run's output, as `status` prints it.
    mutating func addOutput(_ output: [String]) {
        guard !output.isEmpty else { return }
        lines.append("output (last \(output.count) lines):")
        lines.append(contentsOf: output)
    }

    var text: String { lines.joined(separator: "\n") }

    static func response(_ blocks: [AutomationFields], code: Int32 = AutomationExitCode.success) -> AutomationResponse {
        AutomationResponse(exitCode: code, stdout: blocks.map(\.text).joined(separator: "\n\n"), stderr: "")
    }

    static func refusal(_ error: Error) -> AutomationResponse {
        if let refusal = error as? AutomationRefusal {
            return AutomationResponse(exitCode: AutomationExitCode.refused, stdout: "", stderr: refusal.message)
        }
        return AutomationResponse(exitCode: AutomationExitCode.communication, stdout: "", stderr: error.localizedDescription)
    }

    static func usage(_ problem: String) -> AutomationResponse {
        AutomationResponse(exitCode: AutomationExitCode.usage, stdout: "", stderr: problem)
    }

    /// The last lines of a daemon's log, cut like `AutomationService` cuts a command's.
    static func tail(_ logs: RingBuffer<LogLine>?) -> [String] {
        (logs?.elements ?? []).suffix(AutomationLimits.outputLines).map {
            $0.text.count > AutomationLimits.maxLineLength
                ? String($0.text.prefix(AutomationLimits.maxLineLength)) + "…" : $0.text
        }
    }
}
