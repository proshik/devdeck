import Foundation

// MARK: - Protocol

/// Scans for OOM kills after a failed run. Behind a protocol → tested with a fake.
protocol OOMInspecting: Sendable {
    func scan() -> OOMReport
}

/// Scan result: OOMKilled pods (kubectl) + raw OOM lines from the node's dmesg.
/// dmesg catches victims OUTSIDE pods (e.g. docker build inside the node) that kubectl does not see.
struct OOMReport: Equatable {
    let events: [OOMEvent]
    let dmesgLines: [String]
    var isEmpty: Bool { events.isEmpty && dmesgLines.isEmpty }
}

// MARK: - OOMEvent

/// A container whose last exit was OOMKilled (`lastState.terminated.reason`).
struct OOMEvent: Equatable {
    let namespace: String
    let pod: String
    let container: String
    let restartCount: Int
    let finishedAt: String?

    /// Parser for `kubectl get pods -A -o json`. Broken JSON → empty result.
    static func parseOOMKilled(_ json: String) -> [OOMEvent] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["items"] as? [[String: Any]] else { return [] }
        var events: [OOMEvent] = []
        for item in items {
            let meta = item["metadata"] as? [String: Any]
            let statuses = (item["status"] as? [String: Any])?["containerStatuses"] as? [[String: Any]] ?? []
            for cs in statuses {
                guard let terminated = (cs["lastState"] as? [String: Any])?["terminated"] as? [String: Any],
                      terminated["reason"] as? String == "OOMKilled" else { continue }
                events.append(OOMEvent(
                    namespace: meta?["namespace"] as? String ?? "?",
                    pod: meta?["name"] as? String ?? "?",
                    container: cs["name"] as? String ?? "?",
                    restartCount: cs["restartCount"] as? Int ?? 0,
                    finishedAt: terminated["finishedAt"] as? String))
            }
        }
        return events
    }
}

// MARK: - LiveOOMInspector

/// Live scan: kubectl + dmesg via minikube ssh. Blocking (~1 s) —
/// call ONLY off the main thread. Tools unavailable → empty report.
final class LiveOOMInspector: OOMInspecting {
    func scan() -> OOMReport {
        OOMReport(events: scanKubectl(), dmesgLines: scanDmesg())
    }

    private func scanKubectl() -> [OOMEvent] {
        let args = ["get", "pods", "-A", "-o", "json"]
        guard let out = ProcessTree.run("/opt/homebrew/bin/kubectl", args)
                ?? ProcessTree.run("/usr/bin/env", ["kubectl"] + args) else { return [] }
        return OOMEvent.parseOOMKilled(out)
    }

    private func scanDmesg() -> [String] {
        let script = "dmesg 2>/dev/null | grep -iE 'killed process|oom-kill' | tail -5"
        let args = ["ssh", "--", script]
        guard let out = ProcessTree.run("/opt/homebrew/bin/minikube", args)
                ?? ProcessTree.run("/usr/bin/env", ["minikube"] + args) else { return [] }
        return out.split(whereSeparator: \.isNewline).map(String.init)
    }
}
