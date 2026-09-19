import Foundation
import Darwin

/// A process identity that survives PID reuse: the same pid with a different start time is a
/// different process and must not inherit the old one's energy.
struct ProcessKey: Hashable, Sendable {
    let pid: Int32
    let startAbstime: UInt64
}

/// Cumulative energy a process has used since it started (Apple Silicon `ri_energy_nj`).
struct ProcessEnergy: Equatable, Sendable {
    let key: ProcessKey
    /// Executable path, or the bare process name when the path can't be read.
    let path: String
    let energyNJ: UInt64
}

protocol ProcessEnergyProbing: Sendable {
    /// Every process this user may inspect. Processes of root and other users (WindowServer,
    /// kernel_task) are refused by the kernel and simply absent.
    func snapshot() -> [ProcessEnergy]
}

struct LiveProcessEnergyProbe: ProcessEnergyProbing {
    func snapshot() -> [ProcessEnergy] {
        let estimate = proc_listallpids(nil, 0)
        guard estimate > 0 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(estimate) + 64)   // headroom for new processes
        let count = pids.withUnsafeMutableBytes { proc_listallpids($0.baseAddress, Int32($0.count)) }
        guard count > 0 else { return [] }

        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var result: [ProcessEnergy] = []
        result.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            var info = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                    proc_pid_rusage(pid, RUSAGE_INFO_V6, $0)
                }
            }
            guard rc == 0 else { continue }   // EPERM for other users' processes, or already gone
            var path = ""
            if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
                path = String(cString: pathBuffer)
            } else if proc_name(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
                path = String(cString: pathBuffer)
            }
            guard !path.isEmpty else { continue }
            result.append(ProcessEnergy(key: ProcessKey(pid: pid, startAbstime: info.ri_proc_start_abstime),
                                        path: path, energyNJ: info.ri_energy_nj))
        }
        return result
    }
}

/// One row of the "who drains the battery" list.
struct EnergyConsumer: Equatable {
    let name: String
    let joules: Double
    /// Fraction of all the energy counted in this tally (0…1).
    let share: Double
    /// Average draw over the whole tally period.
    let averageWatts: Double
}

/// Energy used per process since a baseline (the moment the Mac went on battery). Pure — the
/// model feeds it snapshots.
///
/// The kernel counters are cumulative per process, so one baseline plus later snapshots is enough;
/// snapshots only need to be frequent enough to catch processes before they exit — an exited
/// process keeps what it was last seen with.
struct EnergyTally {
    let since: Date
    /// The unplug itself wasn't observed (DevDeck started, or monitoring was switched on, already on
    /// battery), so `since` is when watching began and earlier drain is missing.
    let missedUnplug: Bool
    private(set) var lastUpdate: Date
    private var baseline: [ProcessKey: UInt64]
    private var consumed: [ProcessKey: (path: String, nanojoules: UInt64)]

    init(baseline snapshot: [ProcessEnergy], at date: Date, missedUnplug: Bool) {
        since = date
        lastUpdate = date
        self.missedUnplug = missedUnplug
        baseline = Dictionary(snapshot.map { ($0.key, $0.energyNJ) }, uniquingKeysWith: { first, _ in first })
        consumed = [:]
    }

    mutating func update(_ snapshot: [ProcessEnergy], at date: Date) {
        for process in snapshot {
            let base = baseline[process.key] ?? 0   // started after the baseline → counts from zero
            let used = process.energyNJ > base ? process.energyNJ - base : 0
            if used > consumed[process.key]?.nanojoules ?? 0 {
                consumed[process.key] = (process.path, used)
            }
        }
        lastUpdate = max(lastUpdate, date)
    }

    /// The heaviest consumers, grouped by display name (an app with its helpers is one row).
    func top(_ limit: Int) -> [EnergyConsumer] {
        var byName: [String: UInt64] = [:]
        for entry in consumed.values {
            byName[Self.displayName(path: entry.path), default: 0] += entry.nanojoules
        }
        let total = Double(byName.values.reduce(0, +))
        guard total > 0 else { return [] }
        let seconds = max(1, lastUpdate.timeIntervalSince(since))
        return byName
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map { name, nanojoules in
                let joules = Double(nanojoules) / 1e9
                return EnergyConsumer(name: name, joules: joules, share: Double(nanojoules) / total,
                                      averageWatts: joules / seconds)
            }
    }

    /// Row name of the Virtualization.framework VM. Rendered as "VM <engine>" by the popover:
    /// which engine owns the VM process can't be told from the path, the active engine can.
    static let vmName = "VM"

    /// Human name for an executable path.
    /// - The Virtualization.framework VM process → `vmName`. Its parent is launchd, so the owner
    ///   can't be told cheaply; any engine's VM is lumped into one "VM" row and the popover names
    ///   it after the active engine.
    /// - Claude Code installs its binary under a version-number name → "Claude Code".
    /// - Anything inside an `.app` bundle → the outermost app's name, so helpers join their app.
    /// - Otherwise the executable's file name.
    static func displayName(path: String) -> String {
        if path.contains("Virtualization.framework"), path.hasSuffix("VirtualMachine") { return vmName }
        if path.contains("/claude/versions/") { return "Claude Code" }
        let components = path.split(separator: "/")
        if let app = components.first(where: { $0.hasSuffix(".app") }) {
            return String(app.dropLast(4))
        }
        return components.last.map(String.init) ?? path
    }
}
