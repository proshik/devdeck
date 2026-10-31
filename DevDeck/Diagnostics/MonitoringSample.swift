import Foundation
import Darwin
import IOKit
import IOKit.ps

struct CPUCounters: Equatable, Sendable {
    let user: UInt64
    let system: UInt64
    let idle: UInt64
    let nice: UInt64
}

struct CPUBusyDelta {
    private var previous: CPUCounters?
    mutating func reset() { previous = nil }
    mutating func consume(_ current: CPUCounters?) -> Double? {
        defer { previous = current }
        guard let current, let previous,
              current.user >= previous.user, current.system >= previous.system,
              current.idle >= previous.idle, current.nice >= previous.nice else { return nil }
        let busy = Double(current.user - previous.user) + Double(current.system - previous.system)
            + Double(current.nice - previous.nice)
        let total = busy + Double(current.idle - previous.idle)
        return total > 0 ? busy / total * 100 : nil
    }
}

struct PowerDetails: Equatable, Sendable {
    var hasBattery = false
    var cycles: Int?
    var health: String?
    var adapterWatts: Double?
    /// Battery terminal power, not system draw. Positive = charging, negative = discharging.
    var batteryWatts: Double?

    static func publicHealth(_ sources: [[String: Any]]) -> String? {
        guard let source = sources.first(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) else { return nil }
        return [kIOPSBatteryHealthConditionKey, kIOPSBatteryHealthKey].compactMap { source[$0] as? String }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    static func decode(_ properties: [String: Any]?) -> Self {
        guard let p = properties else { return .init() }
        var result = Self(hasBattery: true)
        result.cycles = (p["CycleCount"] as? NSNumber).map { $0.intValue }.flatMap { $0 >= 0 ? $0 : nil }
        result.health = p["BatteryHealth"] as? String
        if let adapter = p["AdapterDetails"] as? [String: Any], let watts = adapter["Watts"] as? NSNumber,
           watts.doubleValue > 0 { result.adapterWatts = watts.doubleValue }
        if let voltage = p["Voltage"] as? NSNumber, let current = p["InstantAmperage"] as? NSNumber,
           voltage.doubleValue > 0 {
            // IOKit may encode negative mA as an unsigned two's-complement number.
            let amps = current.int64Value
            if abs(Double(amps)) < 100_000 {
                result.batteryWatts = voltage.doubleValue * Double(amps) / 1_000_000
            }
        }
        return result
    }
}

protocol MonitoringPowerProbing: Sendable { func sample() -> PowerDetails }
struct LiveMonitoringPowerProbe: MonitoringPowerProbing {
    func sample() -> PowerDetails {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as NSArray as [AnyObject]
        let descriptions = sources.compactMap { IOPSGetPowerSourceDescription(info, $0)?.takeUnretainedValue() as? [String: Any] }
        var details = registryDetails()
        details.health = PowerDetails.publicHealth(descriptions)
        if descriptions.contains(where: { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }) { details.hasBattery = true }
        return details
    }
    private func registryDetails() -> PowerDetails {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return .init() }
        defer { IOObjectRelease(service) }
        var properties: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let dictionary = properties?.takeRetainedValue() as? [String: Any] else { return .init() }
        return .decode(dictionary)
    }
}

struct MacMonitoringSample: Sendable {
    var cpu: CPUCounters?
    var loadAverage: Double?
    var memory: SystemMemory?
    var host: HostMetricsSample?
    var diskUsedBytes: UInt64?
    var diskTotalBytes: UInt64?
    var uptime: TimeInterval?
}

/// Restore tabs keeps its legacy sentinel; monitoring converts it to unavailable.
struct MonitoringUptime {
    let source: any BootTimeProviding
    let now: () -> Date
    func sample() -> TimeInterval? {
        let boot = source.bootTime()
        let current = now()
        guard boot.timeIntervalSince1970.isFinite, current.timeIntervalSince1970.isFinite,
              boot > Date(timeIntervalSince1970: 0), boot <= current else { return nil }
        return current.timeIntervalSince(boot)
    }
}

protocol MonitoringKernelProbing: Sendable { func sample(includeMemory: Bool) -> MacMonitoringSample }
struct LiveMonitoringKernelProbe: MonitoringKernelProbing {
    var readBase: @Sendable () -> MacMonitoringSample = { Self.baseSample() }
    var readMemory: @Sendable () -> SystemMemory? = { SystemMemory.currentIfAvailable() }
    var readHost: @Sendable () -> HostMetricsSample? = { LiveHostMetricsProbe().sample(buildPID: nil) }

    func sample(includeMemory: Bool) -> MacMonitoringSample {
        var value = readBase()
        value.memory = includeMemory ? readMemory() : nil
        value.host = includeMemory ? readHost() : nil
        return value
    }

    private static func baseSample() -> MacMonitoringSample {
        var ticks = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        let ok = withUnsafeMutablePointer(to: &ticks) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        } == KERN_SUCCESS
        let cpu = ok ? CPUCounters(user: UInt64(ticks.cpu_ticks.0), system: UInt64(ticks.cpu_ticks.1),
                                   idle: UInt64(ticks.cpu_ticks.2), nice: UInt64(ticks.cpu_ticks.3)) : nil
        var load = 0.0
        let loadOK = getloadavg(&load, 1) == 1
        var disk = statfs()
        let diskOK = statfs("/", &disk) == 0 && disk.f_blocks > 0 && disk.f_bfree <= disk.f_blocks
        // APFS space shared by the root filesystem's container: allocated = total − free.
        let unit = UInt64(disk.f_bsize)
        return .init(cpu: cpu, loadAverage: loadOK ? load : nil,
                     memory: nil, host: nil,
                     diskUsedBytes: diskOK ? (disk.f_blocks - disk.f_bfree) * unit : nil,
                     diskTotalBytes: diskOK ? disk.f_blocks * unit : nil,
                     uptime: MonitoringUptime(source: LiveBootTime(), now: Date.init).sample())
    }
}

struct TimedMonitoring<Value> {
    let date: Date
    let value: Value
}
struct MacMonitoringValues {
    let sample: MacMonitoringSample
    let cpuBusyPercent: Double?
    let swapInBytesPerSecond: Double?
    let swapOutBytesPerSecond: Double?
}
struct ContainerMonitoringValues {
    let engine: ContainerEngineKind?
    let engineName: String?
    let running: Bool
    let vm: VMMemoryInfo?
    let minikube: MinikubeSample?
    let disk: VMDiskInfo?
    let cluster: ClusterHealth?
    var diskMeasuredAt: Date? = nil
}
struct EnergyMonitoringValues {
    let battery: BatteryState?
    let details: PowerDetails
    let consumers: [EnergyConsumer]
    let tally: EnergyTally?
    let isDischarging: Bool
}
struct DeckMonitoringSnapshot {
    var mac: TimedMonitoring<MacMonitoringValues>?
    var containers: TimedMonitoring<ContainerMonitoringValues>?
    var energy: TimedMonitoring<EnergyMonitoringValues>?
}
struct MonitoringHistoryPoint: Identifiable {
    let id = UUID()
    let date: Date
    let cpu: Double?
    let memory: Double?
    let battery: Double?
    var vmMemory: Double? = nil
}
