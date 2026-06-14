import Foundation
import Darwin

/// Finds orphaned daemon processes and kills their subtree — behind a protocol
/// so that adopting a daemon can be tested with a fake, without real processes.
@MainActor
protocol DaemonReaper {
    /// PID of an orphaned process (reparented to launchd → `ppid == 1`) whose command
    /// matches `command`. Returns `nil` if no such process exists. Searching by command
    /// is resilient to legacy orphans and crashes (does not depend on a saved PID).
    func findOrphan(matchingCommand command: String) -> Int32?
    /// Kill a process and its entire subtree (SIGTERM). Needed for grandchildren:
    /// `zsh -lc "kubectl …"` may keep `kubectl` as a child process while the port lives there.
    func killTree(pid: Int32)
}

/// Real implementation via `ps`/`kill`. Called infrequently (start-adoption, stop), on main.
struct LiveDaemonReaper: DaemonReaper {
    nonisolated init() {}

    func findOrphan(matchingCommand command: String) -> Int32? {
        let needle = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return nil }
        guard let out = ProcessTree.run("/bin/ps", ["-axo", "pid=,ppid=,command="]) else { return nil }
        for line in out.split(separator: "\n") {
            // Line format: "<pid> <ppid> <command…>".
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = Int32(parts[0]), let ppid = Int32(parts[1]) else { continue }
            guard ppid == 1 else { continue }            // orphans only (reparented to launchd)
            if parts[2].contains(needle) { return pid }  // same command
        }
        return nil
    }

    func killTree(pid: Int32) {
        ProcessTree.terminate(pid)
    }
}
