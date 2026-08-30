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

/// Comparing two boot times.
///
/// Exact `Date` equality is wrong here, and wrong in the most damaging way available. `kern.boottime`
/// is not a constant the kernel merely remembers: XNU recomputes it whenever the wall clock is set,
/// and NTP corrects the clock a minute or two into every single boot — so the value read at login
/// can differ, in its microseconds, from the value read an hour later in the same boot. With exact
/// equality that jitter fires both failure modes at once: the snapshot stops looking like it came
/// from this boot (restore everything again, on top of the tabs already open), and `restoredBootTime`
/// stops matching (restore again on every Ghostty launch, for the rest of the boot).
///
/// Whole-second granularity, expressed as a one-second tolerance so a shift across a second
/// boundary is not counted as a different boot either. It stays well under the shortest possible
/// reboot — a machine cannot go down and come back inside a second — so absorbing the jitter never
/// costs the ability to tell a real reboot apart.
enum BootInstant {
    static let tolerance: TimeInterval = 1

    /// nil is never the same boot: "we have no record" must not read as "already handled".
    static func same(_ lhs: Date, _ rhs: Date?) -> Bool {
        guard let rhs else { return false }
        return abs(lhs.timeIntervalSince(rhs)) < tolerance
    }
}
