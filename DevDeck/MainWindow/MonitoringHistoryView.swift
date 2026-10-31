import SwiftUI
import Charts

struct MonitoringHistoryView: View {
    @Environment(DeckMonitoringModel.self) private var model
    let section: MonitoringSection
    static func hasMeasurements(_ points: [MonitoringHistoryPoint], section: MonitoringSection) -> Bool {
        points.contains { point in
            switch section {
            case .mac: point.cpu != nil || point.memory != nil
            case .containers: point.vmMemory != nil
            case .energy: point.battery != nil
            }
        }
    }
    var body: some View {
        let points = model.history
        Chart {
            ForEach(points) { point in
                if section == .mac {
                    if let value = point.cpu { LineMark(x: .value("Time", point.date), y: .value("%", value)).foregroundStyle(by: .value("Metric", L10n.monitoringCPU)) }
                    if let value = point.memory { LineMark(x: .value("Time", point.date), y: .value("%", value)).foregroundStyle(by: .value("Metric", L10n.memory)) }
                } else if section == .containers {
                    if let value = point.vmMemory { LineMark(x: .value("Time", point.date), y: .value("%", value)).foregroundStyle(by: .value("Metric", L10n.deckContainers)) }
                } else if let value = point.battery {
                    LineMark(x: .value("Time", point.date), y: .value("%", value)).foregroundStyle(by: .value("Metric", L10n.deckEnergy))
                }
            }
        }
        .chartYScale(domain: 0...100)
        .frame(height: 160)
        .overlay { if !Self.hasMeasurements(points, section: section) { Text(L10n.monitoringWaitingHistory).foregroundStyle(.secondary).padding(4).background(.background) } }
        .accessibilityLabel(L10n.monitoringHistoryTitle)
    }
}
