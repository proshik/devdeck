import Foundation

// MARK: - Protocol

/// A snapshot of memory inside the minikube node. Behind a protocol → tested with a fake (no ssh).
protocol MinikubeProbing: Sendable {
    func sample() -> MinikubeSample?
}

// MARK: - MinikubeSample

/// minikube node memory from inside the VM. `anon` (memory.stat) is non-reclaimable memory,
/// the real OOM-risk signal: `memory.current`/`memory.peak` get saturated by the page cache
/// and always sit at the limit. The limit is the node's cgroup namespace root `memory.max`
/// (= the docker limit of the node container = `minikube --memory`).
struct MinikubeSample: Equatable {
    let anonBytes: UInt64
    let limitBytes: UInt64
    let rustcCount: Int
    let rustcRSSBytes: UInt64

    var fraction: Double { limitBytes > 0 ? Double(anonBytes) / Double(limitBytes) : 0 }
    var headroomFraction: Double { max(0, 1 - fraction) }

    func format() -> String {
        let gib = 1_073_741_824.0
        let percent = limitBytes > 0 ? Int((fraction * 100).rounded()) : 0
        return String(format: "anon %.1f / %.1f GiB · %d%%",
                      Double(anonBytes) / gib, Double(limitBytes) / gib, percent)
    }

    /// The script run inside the node in a single ssh hop (≈0.45 s).
    static let probeScript =
        "grep '^anon ' /sys/fs/cgroup/memory.stat; cat /sys/fs/cgroup/memory.max; ps -e -o rss=,comm="

    /// Parser for `probeScript` output: an `anon N` line, then the limit (a number or `max`),
    /// then `RSS_KiB comm` lines. Without anon or a numeric limit → nil.
    static func parse(_ output: String) -> MinikubeSample? {
        var anon: UInt64?
        var limit: UInt64?
        var rustcCount = 0
        var rustcRSSKiB: UInt64 = 0
        for line in output.split(whereSeparator: \.isNewline) {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            switch tokens.count {
            case 1 where limit == nil:
                limit = UInt64(tokens[0])           // "max" → not a number → we stay without a limit
            case 2 where tokens[0] == "anon":
                anon = UInt64(tokens[1])
            case 2 where tokens[1] == "rustc":
                guard let rss = UInt64(tokens[0]) else { continue }
                rustcCount += 1
                rustcRSSKiB += rss
            default:
                continue
            }
        }
        guard let anon, let limit, limit > 0 else { return nil }
        return MinikubeSample(anonBytes: anon, limitBytes: limit,
                              rustcCount: rustcCount, rustcRSSBytes: rustcRSSKiB * 1024)
    }
}

// MARK: - MinikubeRunStats

/// Per-run accumulator: anon peak + independent maxima for rustc.
struct MinikubeRunStats: Equatable {
    private(set) var peak: MinikubeSample
    private(set) var maxRustcCount: Int
    private(set) var maxRustcRSSBytes: UInt64

    init(first: MinikubeSample) {
        peak = first
        maxRustcCount = first.rustcCount
        maxRustcRSSBytes = first.rustcRSSBytes
    }

    mutating func absorb(_ s: MinikubeSample) {
        if s.anonBytes > peak.anonBytes { peak = s }
        maxRustcCount = max(maxRustcCount, s.rustcCount)
        maxRustcRSSBytes = max(maxRustcRSSBytes, s.rustcRSSBytes)
    }
}

// MARK: - LiveMinikubeProbe

/// The real probe: one `minikube ssh` per sample. Blocking (~0.5 s) —
/// call ONLY off the main thread. minikube not running → empty output → nil.
final class LiveMinikubeProbe: MinikubeProbing {
    func sample() -> MinikubeSample? {
        let args = ["ssh", "--", MinikubeSample.probeScript]
        guard let out = ProcessTree.run("/opt/homebrew/bin/minikube", args)
                ?? ProcessTree.run("/usr/bin/env", ["minikube"] + args) else { return nil }
        return MinikubeSample.parse(out)
    }
}
