import Foundation

/// At-a-glance health of the local dev stack (colima VM → minikube node).
enum ClusterHealthLevel: Equatable {
    case healthy    // colima up + minikube fully Running
    case degraded   // colima up but minikube not fully Running
    case down       // colima stopped → nothing works
    case unknown    // couldn't determine (colima/minikube not installed or errored)
}

struct ClusterHealth: Equatable {
    let level: ClusterHealthLevel
    let detail: String
}

/// Pure verdict from probed inputs. `colimaRunning` is nil when colima couldn't be queried;
/// `minikubeStatus` is the raw `minikube status` text (nil when it couldn't be queried).
func clusterHealthVerdict(colimaRunning: Bool?, minikubeStatus: String?) -> ClusterHealth {
    guard let colimaRunning else { return ClusterHealth(level: .unknown, detail: "colima unavailable") }
    guard colimaRunning else { return ClusterHealth(level: .down, detail: "colima stopped") }
    guard let mk = minikubeStatus?.lowercased() else {
        return ClusterHealth(level: .degraded, detail: "colima up · minikube unknown")
    }
    let allUp = mk.contains("host: running")
        && mk.contains("kubelet: running")
        && mk.contains("apiserver: running")
    return allUp
        ? ClusterHealth(level: .healthy, detail: "colima up · minikube Running")
        : ClusterHealth(level: .degraded, detail: "colima up · minikube degraded")
}

/// Parse the colima profile `status` field from `colima list --json` (one JSON object per line).
/// Returns nil when the JSON can't be read.
func parseColimaRunning(_ json: String) -> Bool? {
    let line = json.split(whereSeparator: \.isNewline).first.map(String.init) ?? json
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let status = obj["status"] as? String else { return nil }
    return status.caseInsensitiveCompare("Running") == .orderedSame
}

// MARK: - Probe

protocol ClusterHealthProbing: Sendable {
    func sample() -> ClusterHealth
}

/// The real probe: cheap `colima list --json` (status) + `minikube status` (node). Blocking → call off-main.
struct LiveClusterHealthProbe: ClusterHealthProbing {
    func sample() -> ClusterHealth {
        let colimaJSON = ProcessTree.run("/opt/homebrew/bin/colima", ["list", "--json"])
            ?? ProcessTree.run("/usr/bin/env", ["colima", "list", "--json"])
        let colimaRunning = colimaJSON.flatMap(parseColimaRunning)
        // minikube status exits non-zero when stopped but still prints the status text to stdout.
        let minikube = ProcessTree.run("/opt/homebrew/bin/minikube", ["status"])
            ?? ProcessTree.run("/usr/bin/env", ["minikube", "status"])
        return clusterHealthVerdict(colimaRunning: colimaRunning, minikubeStatus: minikube)
    }
}
