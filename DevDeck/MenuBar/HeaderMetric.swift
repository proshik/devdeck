import Foundation

/// The popover header's metrics, in display order. One place for their names and the one-line
/// explanations shown as tooltips in the popover and as a reference list in Settings.
enum HeaderMetric: CaseIterable {
    case memory, swap, cluster, vmColima, vmMinikube, pressure, diskVM, swapRate, cpuLoad

    var title: String {
        switch self {
        case .memory: return L10n.memory
        case .swap: return L10n.swap
        case .cluster: return L10n.cluster
        case .vmColima: return "VM colima"
        case .vmMinikube: return "VM minikube"
        case .pressure: return L10n.pressure
        case .diskVM: return L10n.diskVM
        case .swapRate: return L10n.swapRate
        case .cpuLoad: return L10n.cpuLoad
        }
    }

    var help: String { L10n.metricHelp(self) }
}
