import Foundation

// MARK: - Protocol

/// A snapshot of VM memory. Behind a protocol → ProcessManager/popover are tested with a fake.
protocol VMMemoryProbing: Sendable {
    func sample() -> VMMemoryInfo?
}

// MARK: - VMMemoryInfo

/// VM memory (hypervisor RSS against the limit). Binary GiB — like SystemMemory.
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

/// The real probe: the colima hypervisor process (vz) + its footprint + the colima limit.
/// Caches the PID and the limit (a re-sample = only the footprint, without spawning processes).
final class LiveVMMemoryProbe: VMMemoryProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var cachedPID: Int32?
    private var cachedLimit: UInt64?

    func sample() -> VMMemoryInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let pid = resolvePID() else { return nil }
        guard let limit = resolveLimit() else { return nil }
        let used = ProcessTree.physFootprint(pid)
        guard used > 0 else { return nil }
        return VMMemoryInfo(usedBytes: used, limitBytes: limit)
    }

    private func resolvePID() -> Int32? {
        if let pid = cachedPID, ProcessTree.isAlive(pid) { return pid }
        guard let out = ProcessTree.run("/usr/bin/pgrep",
            ["-f", "com.apple.Virtualization.VirtualMachine"]) else { cachedPID = nil; return nil }
        let pids = out.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        let best = pids.max(by: { ProcessTree.physFootprint($0) < ProcessTree.physFootprint($1) })
        cachedPID = best
        return best
    }

    private func resolveLimit() -> UInt64? {
        if let limit = cachedLimit { return limit }
        guard let json = ProcessTree.run("/opt/homebrew/bin/colima", ["list", "--json"])
                ?? ProcessTree.run("/usr/bin/env", ["colima", "list", "--json"]) else { return nil }
        let line = json.split(whereSeparator: \.isNewline).first.map(String.init) ?? json
        cachedLimit = VMMemoryInfo.parseColimaLimitBytes(line)
        return cachedLimit
    }
}
