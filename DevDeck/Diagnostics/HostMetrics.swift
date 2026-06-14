import Foundation
import Darwin

/// Kernel verdict on memory shortage (`kern.memorystatus_vm_pressure_level`).
enum MemoryPressureLevel: Int, Equatable {
    case normal = 1
    case warning = 2
    case critical = 4

    init(raw: Int32) { self = MemoryPressureLevel(rawValue: Int(raw)) ?? .normal }
}

/// Pages/sec swap rate from two cumulative counter samples. Negative deltas
/// (counter reset / reboot) clamp to 0.
func swapRatePagesPerSec(prevIn: UInt64, prevOut: UInt64,
                         curIn: UInt64, curOut: UInt64,
                         dtSeconds: Double) -> (inPerSec: Double, outPerSec: Double) {
    guard dtSeconds > 0 else { return (0, 0) }
    let dIn = curIn >= prevIn ? Double(curIn - prevIn) : 0
    let dOut = curOut >= prevOut ? Double(curOut - prevOut) : 0
    return (dIn / dtSeconds, dOut / dtSeconds)
}

/// A host-side memory snapshot beyond what `SystemMemory` exposes.
struct HostMetricsSample: Equatable {
    let pressure: MemoryPressureLevel
    let swapInsPages: UInt64       // cumulative since boot
    let swapOutsPages: UInt64      // cumulative since boot
    let compressorPages: UInt64
    let totalBytes: UInt64
    let buildFootprintBytes: UInt64   // RSS footprint of the tracked build PID (0 if none)

    func compressorBytes(pageSize: UInt64) -> UInt64 { compressorPages * pageSize }
    func compressorFraction(pageSize: UInt64) -> Double {
        totalBytes > 0 ? Double(compressorBytes(pageSize: pageSize)) / Double(totalBytes) : 0
    }

    /// "64.0 MB/s" — binary MiB/s, or "0 MB/s" when idle. A pure function.
    static func formatRate(pagesPerSec: Double, pageSize: UInt64) -> String {
        let bytesPerSec = pagesPerSec * Double(pageSize)
        if bytesPerSec < 1 { return "0 MB/s" }
        return String(format: "%.1f MB/s", bytesPerSec / 1_048_576.0)
    }
}

/// Behind a protocol → ProcessManager/popover are tested with a fake (no kernel reads).
protocol HostMetricsProbing: Sendable {
    /// `buildPID` — footprint that PID (the running build), or nil to skip it.
    func sample(buildPID: Int32?) -> HostMetricsSample
}

/// Real probe: sysctl pressure level + HOST_VM_INFO64 swap/compressor counters + PID footprint.
struct LiveHostMetricsProbe: HostMetricsProbing {
    func sample(buildPID: Int32?) -> HostMetricsSample {
        let total = ProcessInfo.processInfo.physicalMemory

        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        } == KERN_SUCCESS

        let footprint = buildPID.map { ProcessTree.physFootprint($0) } ?? 0
        return HostMetricsSample(
            pressure: MemoryPressureLevel(raw: level),
            swapInsPages: ok ? UInt64(stats.swapins) : 0,
            swapOutsPages: ok ? UInt64(stats.swapouts) : 0,
            compressorPages: ok ? UInt64(stats.compressor_page_count) : 0,
            totalBytes: total,
            buildFootprintBytes: footprint)
    }
}

/// Page size for rate/compressor conversions (16 KiB on Apple Silicon, 4 KiB on Intel).
let hostPageSize = UInt64(vm_page_size)
