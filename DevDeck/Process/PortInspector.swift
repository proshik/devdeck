import Foundation

/// A process listening on a local TCP port.
struct PortOccupant: Equatable, Sendable {
    let pid: Int32
    let processName: String
}

/// Looks up who is listening on a local port — behind a protocol so the port-conflict
/// flow is tested with a fake. Synchronous and blocking (lsof takes ~100 ms);
/// `ProcessManager` always calls it from a detached task.
protocol PortInspector: Sendable {
    func occupant(ofPort port: Int) -> PortOccupant?
}

/// Real implementation via `lsof`. `-F pc` prints machine-readable field lines:
/// `p<pid>` then `c<process name>` per process; we take the first complete pair.
/// lsof exits 1 with empty output when nothing listens → nil.
struct LivePortInspector: PortInspector {
    func occupant(ofPort port: Int) -> PortOccupant? {
        guard let out = ProcessTree.run("/usr/sbin/lsof", ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fpc"]),
              !out.isEmpty else { return nil }
        var pid: Int32?
        for line in out.split(separator: "\n") {
            switch line.first {
            case "p": pid = Int32(line.dropFirst())
            case "c": if let pid { return PortOccupant(pid: pid, processName: String(line.dropFirst())) }
            default: continue
            }
        }
        if let pid { return PortOccupant(pid: pid, processName: "?") }
        return nil
    }
}
