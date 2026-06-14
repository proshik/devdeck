import Foundation

struct OOMVerdict: Equatable {
    let isOOM: Bool
    let crate: String?
}

/// Detects an OOM/SIGKILL build failure and the offending crate.
/// - OOM if the exit code is 9 or 137 (128+SIGKILL), or the log tail contains "signal: 9".
/// - The crate is parsed from rustc's ``error: could not compile `NAME` `` line.
func detectOOM(exitCode: Int32, logTail: String) -> OOMVerdict {
    let isOOM = exitCode == 9 || exitCode == 137 || logTail.contains("signal: 9")
    var crate: String?
    if let range = logTail.range(of: #"could not compile `([^`]+)`"#, options: .regularExpression) {
        let match = String(logTail[range])
        if let inner = match.range(of: #"`([^`]+)`"#, options: .regularExpression) {
            crate = String(match[inner]).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
    }
    return OOMVerdict(isOOM: isOOM, crate: crate)
}
