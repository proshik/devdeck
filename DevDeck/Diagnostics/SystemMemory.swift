import Foundation
import Darwin

/// A snapshot of system memory (like "Memory Used" in Activity Monitor).
struct SystemMemory: Equatable {
    let usedBytes: UInt64
    let totalBytes: UInt64
    let swapUsedBytes: UInt64

    init(usedBytes: UInt64, totalBytes: UInt64, swapUsedBytes: UInt64 = 0) {
        self.usedBytes = usedBytes
        self.totalBytes = totalBytes
        self.swapUsedBytes = swapUsedBytes
    }

    var fraction: Double {
        totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0
    }

    /// "Used" = (active + wired + compressed) × pageSize; total = physical RAM; + swap.
    /// On a syscall failure returns used = 0 (the UI shows 0 instead of crashing).
    static func current() -> SystemMemory {
        let total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return SystemMemory(usedBytes: 0, totalBytes: total) }

        let pageSize = UInt64(vm_page_size)
        let used = (UInt64(stats.active_count) + UInt64(stats.wire_count) + UInt64(stats.compressor_page_count)) * pageSize
        return SystemMemory(usedBytes: min(used, total), totalBytes: total, swapUsedBytes: swapUsedBytes())
    }

    /// Swap used (bytes). 0 if swap is unused or unavailable.
    static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// "1.7 GB" — bytes in binary GiB. A pure function (for swap).
    static func formatGiB(_ bytes: UInt64) -> String {
        String(format: "%.1f GB", Double(bytes) / 1_073_741_824.0)
    }

    /// "12.0 / 16 GB · 75%" — binary GiB (how Apple labels RAM, and how htop shows it). A pure function.
    static func format(usedBytes: UInt64, totalBytes: UInt64) -> String {
        let gib = 1_073_741_824.0   // 2³⁰: Apple's "16 GB" = 16 GiB
        let usedGB = Double(usedBytes) / gib
        let totalGB = Double(totalBytes) / gib
        let percent = totalBytes > 0 ? Int((Double(usedBytes) / Double(totalBytes) * 100).rounded()) : 0
        return String(format: "%.1f / %.0f GB · %d%%", usedGB, totalGB, percent)
    }
}
