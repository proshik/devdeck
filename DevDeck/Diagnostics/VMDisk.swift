import Foundation

// MARK: - VMDiskInfo

/// Disk usage of the docker filesystem inside the colima VM. Binary GiB, like the other metrics.
struct VMDiskInfo: Equatable {
    let usedBytes: UInt64
    let totalBytes: UInt64

    var fraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    /// "40 / 97 GB · 41%" — whole GiB (disk sizes don't need decimals).
    func format() -> String {
        let gib = 1_073_741_824.0
        let percent = totalBytes > 0 ? Int((fraction * 100).rounded()) : 0
        return String(format: "%.0f / %.0f GB · %d%%",
                      Double(usedBytes) / gib, Double(totalBytes) / gib, percent)
    }
}

/// Parse `df -Pk <path>` output (POSIX format, 1024-byte blocks): second line,
/// columns 2 (total) and 3 (used). nil on malformed output or zero total.
func parseDF(_ output: String) -> VMDiskInfo? {
    let lines = output.split(whereSeparator: \.isNewline)
    guard lines.count >= 2 else { return nil }
    let cols = lines[1].split(separator: " ", omittingEmptySubsequences: true)
    guard cols.count >= 3,
          let totalK = UInt64(cols[1]), totalK > 0,
          let usedK = UInt64(cols[2]) else { return nil }
    return VMDiskInfo(usedBytes: usedK * 1024, totalBytes: totalK * 1024)
}

// MARK: - Probe

/// Behind a protocol → ProcessManager/popover are tested with a fake (no ssh spawns).
protocol VMDiskProbing: Sendable {
    func sample() -> VMDiskInfo?
}

/// The real probe: `colima ssh -- df -Pk /var/lib/docker`. Blocking (~200-300 ms) → call off-main.
struct LiveVMDiskProbe: VMDiskProbing {
    func sample() -> VMDiskInfo? {
        let out = ProcessTree.run("/opt/homebrew/bin/colima", ["ssh", "--", "df", "-Pk", "/var/lib/docker"])
            ?? ProcessTree.run("/usr/bin/env", ["colima", "ssh", "--", "df", "-Pk", "/var/lib/docker"])
        return out.flatMap(parseDF)
    }
}
