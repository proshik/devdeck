import Foundation

// MARK: - BuildJobsAdvice

struct BuildJobsAdvice: Equatable {
    let effectiveJobs: Int   // what the build will actually use
    let advisedJobs: Int     // safe max for the RAM limit (limit_GB / 2, min 1)
    var overBudget: Bool { effectiveJobs > advisedJobs }
}

/// Reconcile build parallelism with the VM RAM limit.
/// Rule of thumb: ~2 GiB per concurrent rustc → safe jobs = limit_GB / 2.
/// Effective jobs: explicit `-j N` in the command > `CARGO_BUILD_JOBS` env > VM core count.
func adviseJobs(command: String, env: [String: String], vmCpus: Int, limitBytes: UInt64) -> BuildJobsAdvice {
    var effective = max(1, vmCpus)
    if let envJobs = env["CARGO_BUILD_JOBS"].flatMap(Int.init), envJobs > 0 { effective = envJobs }
    if let range = command.range(of: #"-j\s*([0-9]+)"#, options: .regularExpression) {
        let digits = command[range].filter(\.isNumber)
        if let n = Int(digits), n > 0 { effective = n }
    }
    let limitGB = Double(limitBytes) / 1_073_741_824.0
    let advised = max(1, Int(limitGB / 2.0))
    return BuildJobsAdvice(effectiveJobs: effective, advisedJobs: advised)
}

// MARK: - OOMVerdict

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
