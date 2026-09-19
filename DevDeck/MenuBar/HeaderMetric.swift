import Foundation

/// The popover header's metrics. One place for their names and the one-line explanations shown
/// as tooltips in the popover and as a reference list in Settings.
enum HeaderMetric: CaseIterable {
    case memory, swap, cluster, vmEngine, vmMinikube, pressure, diskVM, swapRate, cpuLoad, battery

    /// The VM cell is named after the engine it measures ("VM colima", "VM Docker Desktop");
    /// plain "VM" when no engine is known.
    func title(engineName: String?) -> String {
        switch self {
        case .memory: return L10n.memory
        case .swap: return L10n.swap
        case .cluster: return L10n.cluster
        case .vmEngine: return engineName.map { "VM \($0)" } ?? "VM"
        case .vmMinikube: return "VM minikube"
        case .pressure: return L10n.pressure
        case .diskVM: return L10n.diskVM
        case .swapRate: return L10n.swapRate
        case .cpuLoad: return L10n.cpuLoad
        case .battery: return L10n.battery
        }
    }

    /// The VM memory, VM disk and cluster cells come from colima-only probes (`colima ssh`,
    /// `colima list`). Under any other engine — or none — they have nothing to say and are hidden
    /// rather than left blank.
    func isAvailable(engineKind: ContainerEngineKind?) -> Bool {
        switch self {
        case .vmEngine, .diskVM, .cluster: return engineKind == .colima
        default: return true
        }
    }

    var help: String { L10n.metricHelp(self) }

    /// Grid cells always on screen, in order (the memory bar sits above the grid).
    static let pinned: [HeaderMetric] = [.vmEngine, .diskVM, .cpuLoad]
    /// Grid cells behind the "More" disclosure, in order.
    static let hidden: [HeaderMetric] = [.cluster, .swap, .vmMinikube, .pressure, .swapRate, .battery]

    /// How loudly the collapsed "More" toggle should ask to be opened.
    enum Alarm: Comparable { case none, warning, critical }

    /// The worst state among the hidden metrics; nil inputs mean "no data" and never alarm.
    static func hiddenAlarm(cluster: ClusterHealthLevel?, swap: SwapSeverity?,
                            pressure: MemoryPressureLevel?, swapRateActive: Bool,
                            battery: BatteryState?) -> Alarm {
        var alarms: [Alarm] = []
        switch cluster {
        case .degraded: alarms.append(.warning)
        case .down: alarms.append(.critical)
        default: break
        }
        switch swap {
        case .elevated: alarms.append(.warning)
        case .high: alarms.append(.critical)
        default: break
        }
        switch pressure {
        case .warning: alarms.append(.warning)
        case .critical: alarms.append(.critical)
        default: break
        }
        if swapRateActive { alarms.append(.warning) }
        if let battery, battery.onBattery {
            if battery.percent <= lowBatteryCritical { alarms.append(.critical) }
            else if battery.percent <= lowBatteryWarning { alarms.append(.warning) }
        }
        return alarms.max() ?? .none
    }

    static let lowBatteryWarning = 20
    static let lowBatteryCritical = 10
}
