import Foundation

/// When the machine last booted — behind a protocol so the planner is tested with fixed dates.
protocol BootTimeProviding: Sendable {
    func bootTime() -> Date
}

/// `kern.boottime` is constant for the life of a boot, which is exactly what distinguishes
/// "the laptop restarted" (restore the tabs) from "Ghostty restarted" (leave them alone).
struct LiveBootTime: BootTimeProviding {
    func bootTime() -> Date {
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }
}
