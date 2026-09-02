import Foundation
import Darwin

/// Alarm level of the swap-used cell (see `SystemMemory.swapSeverity`).
enum SwapSeverity { case normal, elevated, high }

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

    /// "Used" as Activity Monitor labels it (see `used`); total = physical RAM; + swap.
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

        let usedBytes = used(internalPages: UInt64(stats.internal_page_count),
                             purgeablePages: UInt64(stats.purgeable_count),
                             wiredPages: UInt64(stats.wire_count),
                             compressorPages: UInt64(stats.compressor_page_count),
                             pageSize: UInt64(vm_page_size))
        return SystemMemory(usedBytes: min(usedBytes, total), totalBytes: total,
                            swapUsedBytes: swapUsedBytes())
    }

    /// "Memory Used" the way Activity Monitor and htop define it: App Memory + Wired + Compressed,
    /// where App Memory is the anonymous (internal) pages that are not purgeable — the bytes
    /// nothing can reclaim for free. The active/inactive split is deliberately not consulted:
    /// `active` mixes in file-backed pages the system can simply drop, and leaves out anonymous
    /// pages that merely went cold, which is how this cell used to read 5.9 GB lighter than both.
    /// A pure function over the counters, so the definition is testable without a syscall.
    static func used(internalPages: UInt64, purgeablePages: UInt64, wiredPages: UInt64,
                     compressorPages: UInt64, pageSize: UInt64) -> UInt64 {
        // Counters are sampled a moment apart and can disagree; unsigned wraparound would peg the bar.
        let appMemory = internalPages > purgeablePages ? internalPages - purgeablePages : 0
        return (appMemory + wiredPages + compressorPages) * pageSize
    }

    /// Swap used (bytes). 0 if swap is unused or unavailable.
    static func swapUsedBytes() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    /// How alarming the swap usage is, as a fraction of physical RAM (machine-independent):
    /// a couple of swapped GB is normal macOS housekeeping, not a signal.
    static func swapSeverity(swapUsedBytes: UInt64, totalRAMBytes: UInt64) -> SwapSeverity {
        guard totalRAMBytes > 0 else { return .normal }
        let fraction = Double(swapUsedBytes) / Double(totalRAMBytes)
        if fraction >= 0.25 { return .high }
        if fraction >= 0.10 { return .elevated }
        return .normal
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
