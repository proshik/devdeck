import Foundation
import Darwin

/// Utilities for working with the process tree (`ps`/`kill`) — nonisolated so they can be called
/// both from main (adopting daemons) and from a background task (terminal runner).
enum ProcessTree {
    /// Signal (SIGTERM by default) to a process and its entire subtree (children before the root).
    static func terminate(_ root: Int32, signal: Int32 = SIGTERM) {
        guard root > 0 else { return }
        for pid in subtree(of: root).reversed() { kill(pid, signal) }
    }

    /// Whether the process is alive (`kill(pid, 0)`), with no side effects.
    static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && kill(pid, 0) == 0
    }

    /// PID plus all descendants (tree traversal via `ps -axo pid,ppid`).
    static func subtree(of root: Int32) -> [Int32] {
        guard let out = run("/bin/ps", ["-axo", "pid=,ppid="]) else { return [root] }
        var childrenOf: [Int32: [Int32]] = [:]
        for line in out.split(separator: "\n") {
            let nums = line.split(separator: " ", omittingEmptySubsequences: true).compactMap { Int32($0) }
            guard nums.count == 2 else { continue }
            childrenOf[nums[1], default: []].append(nums[0])
        }
        var result: [Int32] = []
        var queue = [root]
        while !queue.isEmpty {
            let pid = queue.removeFirst()
            result.append(pid)
            queue.append(contentsOf: childrenOf[pid] ?? [])
        }
        return result
    }

    /// Physical footprint of a process (bytes) via proc_pid_rusage(RUSAGE_INFO_V2). Returns 0 on failure.
    static func physFootprint(_ pid: Int32) -> UInt64 {
        guard pid > 0 else { return 0 }
        var info = rusage_info_v2()
        let rc = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V2, rebound)
            }
        }
        return rc == 0 ? info.ri_phys_footprint : 0
    }

    /// Homebrew bin dirs where dev CLIs and their helpers live (colima→limactl, minikube→docker,
    /// kubectl). `/opt/homebrew/bin` is Apple Silicon, `/usr/local/bin` is Intel.
    static let homebrewBinDirs = ["/opt/homebrew/bin", "/usr/local/bin"]

    /// Prepend the Homebrew bin dirs to `existing` PATH, skipping any already present. Pure.
    ///
    /// A GUI app launched by launchd inherits only a minimal PATH (/usr/bin:/bin:/usr/sbin:/sbin).
    /// Running `colima`/`minikube` by absolute path still works, but they shell out to their own
    /// helpers (`limactl`, `docker`) via PATH and fail — so probes see empty stdout and report
    /// "unknown". Prepending the Homebrew dirs lets those helpers resolve.
    static func augmentedPATH(_ existing: String?) -> String {
        let current = existing ?? ""
        let parts = current.split(separator: ":").map(String.init)
        let missing = homebrewBinDirs.filter { !parts.contains($0) }
        guard !missing.isEmpty else { return current }
        return (missing + (current.isEmpty ? [] : [current])).joined(separator: ":")
    }

    /// Launch a process and return its stdout as a string (or nil on failure). Synchronous.
    static func run(_ launchPath: String, _ args: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        // Inherit the GUI environment (keep HOME/USER) but ensure Homebrew is on PATH so child
        // tools like limactl/docker resolve — otherwise colima/minikube probes come back empty.
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = augmentedPATH(env["PATH"])
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
