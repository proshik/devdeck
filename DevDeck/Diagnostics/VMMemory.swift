import Foundation

// MARK: - Protocol

/// A snapshot of VM memory. Behind a protocol → ProcessManager/popover are tested with a fake.
protocol VMMemoryProbing: Sendable {
    func sample() -> VMMemoryInfo?
    /// Live VM build config (cpus + memory limit) for the `-j` advisory. nil when colima isn't running/known.
    func buildConfig() -> VMBuildConfig?
}

extension VMMemoryProbing {
    // Fakes don't supply a build config; only the live probe queries colima.
    func buildConfig() -> VMBuildConfig? { nil }
}

/// colima cpus + memory limit, used to ground the `-j` build-jobs advisory in live values.
struct VMBuildConfig: Equatable {
    let cpus: Int
    let limitBytes: UInt64
}

// MARK: - VMMemoryInfo

/// Memory used INSIDE the VM (`MemTotal − MemAvailable` against `MemTotal`, from the guest's
/// `/proc/meminfo`). Binary GiB — like SystemMemory.
///
/// Not the hypervisor's footprint on the host: with lima/vz the guest's page cache stays resident
/// in the host process forever (no balloon deflate, no free-page reporting), so that number climbs
/// to the limit after the first big build and never comes back — it measures nothing about
/// OOM risk in the VM. Host-side pressure is the "Pressure"/"Swap" cells.
struct VMMemoryInfo: Equatable {
    let usedBytes: UInt64
    let limitBytes: UInt64

    var fraction: Double { limitBytes > 0 ? Double(usedBytes) / Double(limitBytes) : 0 }
    var headroomFraction: Double { max(0, 1 - fraction) }

    func format() -> String {
        let gib = 1_073_741_824.0
        let percent = limitBytes > 0 ? Int((fraction * 100).rounded()) : 0
        return String(format: "%.1f / %.0f GiB · %d%%",
                      Double(usedBytes) / gib, Double(limitBytes) / gib, percent)
    }

    /// Parse `/proc/meminfo`: used = `MemTotal − MemAvailable`, limit = `MemTotal` (both kB lines).
    /// nil without both keys, with a zero total, or when available exceeds total (garbage).
    static func parseMeminfo(_ output: String) -> VMMemoryInfo? {
        var total: UInt64?
        var available: UInt64?
        for line in output.split(whereSeparator: \.isNewline) {
            let tokens = line.split(separator: " ", omittingEmptySubsequences: true)
            guard tokens.count >= 2, let kb = UInt64(tokens[1]) else { continue }
            switch tokens[0] {
            case "MemTotal:": total = kb
            case "MemAvailable:": available = kb
            default: continue
            }
        }
        guard let total, let available, total > 0, available <= total else { return nil }
        return VMMemoryInfo(usedBytes: (total - available) * 1024, limitBytes: total * 1024)
    }

    /// Limit from `colima list --json` (the `memory` field, bytes). nil on failure/broken JSON.
    static func parseColimaLimitBytes(_ json: String) -> UInt64? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mem = obj["memory"] as? NSNumber else { return nil }
        let v = mem.uint64Value
        return v > 0 ? v : nil
    }

    /// CPU count from `colima list --json` (`cpus`). nil on failure.
    static func parseColimaCpus(_ json: String) -> Int? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cpus = obj["cpus"] as? NSNumber else { return nil }
        let v = cpus.intValue
        return v > 0 ? v : nil
    }
}

// MARK: - LiveVMMemoryProbe

/// The real probe: `colima ssh -- cat /proc/meminfo` (≈0.25 s, blocking → call off-main) for the
/// sample, plus a one-time `colima list --json` read for the `-j` advisory's cpus + limit.
final class LiveVMMemoryProbe: VMMemoryProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var cachedLimit: UInt64?
    private var cachedCpus: Int?

    func sample() -> VMMemoryInfo? {
        let args = ["ssh", "--", "cat", "/proc/meminfo"]
        let out = ProcessTree.run("/opt/homebrew/bin/colima", args)
            ?? ProcessTree.run("/usr/bin/env", ["colima"] + args)
        return out.flatMap(VMMemoryInfo.parseMeminfo)
    }

    /// cpus + limit from a single `colima list --json` read (both cached). nil if either is unavailable.
    func buildConfig() -> VMBuildConfig? {
        lock.lock(); defer { lock.unlock() }
        resolveConfig()
        guard let limit = cachedLimit, let cpus = cachedCpus else { return nil }
        return VMBuildConfig(cpus: cpus, limitBytes: limit)
    }

    /// Read `colima list --json` once and cache both the memory limit and the cpu count.
    private func resolveConfig() {
        if cachedLimit != nil && cachedCpus != nil { return }
        guard let json = ProcessTree.run("/opt/homebrew/bin/colima", ["list", "--json"])
                ?? ProcessTree.run("/usr/bin/env", ["colima", "list", "--json"]) else { return }
        let line = json.split(whereSeparator: \.isNewline).first.map(String.init) ?? json
        if cachedLimit == nil { cachedLimit = VMMemoryInfo.parseColimaLimitBytes(line) }
        if cachedCpus == nil { cachedCpus = VMMemoryInfo.parseColimaCpus(line) }
    }
}
