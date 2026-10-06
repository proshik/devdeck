import SwiftUI

/// Existing measurements, shared by the panel and full window. New sensors belong to a later stage.
struct MonitoringMetricsView: View {
    @Environment(CommandStore.self) private var store
    @Environment(ProcessManager.self) private var manager
    @Environment(EnergyModel.self) private var energy
    @Environment(EngineModel.self) private var engine
    let section: MonitoringSection

    private static let placeholderColor = Color.secondary.opacity(0.45)

    private var metrics: [HeaderMetric] {
        switch section {
        case .mac: [.memory, .swap, .pressure, .swapRate, .cpuLoad]
        case .containers: [.vmEngine, .vmMinikube, .diskVM, .cluster]
        case .energy: [.battery]
        }
    }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let memory = SystemMemory.current()
            VStack(alignment: .leading, spacing: 4) {
                if section == .containers {
                    HStack {
                        Label(engine.activeName ?? L10n.deckContainers, systemImage: "shippingbox")
                        Spacer()
                        Text(engine.isActiveRunning ? L10n.deckEngineRunning : L10n.deckEngineStopped)
                            .foregroundStyle(.secondary)
                    }.frame(minHeight: 24)
                }
                ForEach(metrics.filter { $0.isAvailable(engineKind: engine.activeKind) }, id: \.self) { metric in
                    metricRow(metric, memory: memory)
                }
                if section == .energy {
                    energyConsumers
                    if !store.config.settings.batteryMonitoring {
                        Text(L10n.deckCollectionOff).foregroundStyle(.secondary)
                    }
                }
                if section == .mac && !store.config.settings.hostMemoryMonitoring {
                    Text(L10n.deckCollectionOff).font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.body)
        }
    }

    private func metricRow(_ metric: HeaderMetric, memory: SystemMemory) -> some View {
        let pair = metric == .memory
            ? (SystemMemory.format(usedBytes: memory.usedBytes, totalBytes: memory.totalBytes), pressureColor(memory.fraction))
            : cellValue(metric, memory: memory, swapRate: swapRateText())
        return HStack(spacing: 8) {
            Image(systemName: symbol(metric)).foregroundStyle(.secondary).frame(width: 16)
            Text(metric.title(engineName: engine.activeName))
            Spacer(minLength: 8)
            Text(pair.0.isEmpty ? "—" : pair.0)
                .monospacedDigit().foregroundStyle(pair.0.isEmpty ? .secondary : pair.1)
                .lineLimit(1).minimumScaleFactor(0.85)
        }
        .frame(minHeight: 24)
        .help(metric.help)
        .accessibilityElement(children: .combine)
        .accessibilityValue(pair.0.isEmpty ? L10n.deckNoData : pair.0)
    }

    private func symbol(_ metric: HeaderMetric) -> String {
        switch metric {
        case .memory, .vmEngine, .vmMinikube: "memorychip"
        case .swap, .swapRate: "arrow.up.arrow.down"
        case .pressure: "waveform.path.ecg"
        case .cpuLoad: "cpu"
        case .diskVM: "internaldrive"
        case .cluster: "server.rack"
        case .battery: "battery.100percent"
        }
    }

    /// Live swap rate (↑ out to disk, ↓ in from disk): distinguishes "full but stable" from
    /// "actively thrashing". Gate at ~0.1 MB/s so sub-rounding noise doesn't show. Empty when idle.
    private func swapRateText() -> String {
        let outRate = manager.cachedSwapOutRatePages ?? 0
        let inRate = manager.cachedSwapInRatePages ?? 0
        let gate = 100_000.0
        let outActive = outRate * Double(hostPageSize) >= gate
        let inActive = inRate * Double(hostPageSize) >= gate
        return [
            outActive ? "↑" + HostMetricsSample.formatRate(pagesPerSec: outRate, pageSize: hostPageSize) : nil,
            inActive ? "↓" + HostMetricsSample.formatRate(pagesPerSec: inRate, pageSize: hostPageSize) : nil,
        ].compactMap { $0 }.joined(separator: " ")
    }

    /// Value and colour of one grid cell; a blank value in the placeholder colour means no data.
    private func cellValue(_ metric: HeaderMetric, memory: SystemMemory, swapRate: String) -> (String, Color) {
        switch metric {
        case .memory:
            return ("", Self.placeholderColor)   // drawn as the bar above the grid
        case .cluster:
            guard store.config.settings.clusterHealthMonitoring else { return ("", Self.placeholderColor) }
            let health = manager.cachedClusterHealth
            return (health.map { L10n.clusterHealthValue($0.level) } ?? "",
                    health.map { clusterColor($0.level) } ?? Self.placeholderColor)
        case .swap:
            guard memory.swapUsedBytes > 0 else { return ("", Self.placeholderColor) }
            let color: Color = switch SystemMemory.swapSeverity(
                swapUsedBytes: memory.swapUsedBytes, totalRAMBytes: memory.totalBytes) {
            case .normal: .secondary
            case .elevated: .orange
            case .high: .red
            }
            return (SystemMemory.formatGiB(memory.swapUsedBytes), color)
        case .vmEngine:
            guard store.config.settings.vmMemoryMonitoring else { return ("", Self.placeholderColor) }
            let vm = manager.vmMemorySample()
            return (vm?.format() ?? "", vm.map { pressureColor($0.fraction) } ?? Self.placeholderColor)
        case .vmMinikube:
            guard store.config.settings.minikubeMemoryMonitoring else { return ("", Self.placeholderColor) }
            // minikube memory from inside the VM: 1 s sampler during a run, 15 s refresh otherwise.
            let mk = manager.minikubeSample()
            return (mk.map { $0.format() + ($0.rustcCount > 0 ? " · rustc \($0.rustcCount)" : "") } ?? "",
                    mk.map { pressureColor($0.fraction) } ?? Self.placeholderColor)
        case .pressure:
            guard store.config.settings.hostMemoryMonitoring else { return ("", Self.placeholderColor) }
            let host = manager.cachedHostSample
            return (host.map { L10n.pressureValue($0.pressure) } ?? "",
                    host.map { pressureLevelColor($0.pressure) } ?? Self.placeholderColor)
        case .diskVM:
            guard store.config.settings.vmMemoryMonitoring else { return ("", Self.placeholderColor) }
            let disk = manager.cachedVMDisk
            return (disk.map { $0.format() } ?? "", disk.map { pressureColor($0.fraction) } ?? Self.placeholderColor)
        case .swapRate:
            guard store.config.settings.hostMemoryMonitoring else { return ("", Self.placeholderColor) }
            return swapRate.isEmpty ? ("", Self.placeholderColor) : (swapRate, .orange)
        case .cpuLoad:
            // 1-minute load average, coloured by load-per-core (thrashing during builds).
            var loads = [Double](repeating: 0, count: 3)
            guard getloadavg(&loads, 3) >= 1 else { return ("", Self.placeholderColor) }
            let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
            return (String(format: "%.2f", loads[0]), pressureColor(loads[0] / cores))
        case .battery:
            guard store.config.settings.batteryMonitoring else { return ("", Self.placeholderColor) }
            guard let battery = energy.battery else { return ("", Self.placeholderColor) }
            let color: Color = !battery.onBattery ? .secondary
                : battery.percent <= HeaderMetric.lowBatteryCritical ? .red
                : battery.percent <= HeaderMetric.lowBatteryWarning ? .orange : .green
            return (battery.format(), color)
        }
    }

    /// Who used the battery: live while discharging, frozen as "last discharge" once back on AC.
    @ViewBuilder
    private var energyConsumers: some View {
        if energy.battery != nil, let tally = energy.tally {
            VStack(alignment: .leading, spacing: 3) {
                Text(energyTitle(tally)).foregroundStyle(.secondary)
                if energy.consumers.isEmpty {
                    Text(L10n.energyNoData).foregroundStyle(Self.placeholderColor)
                }
                ForEach(energy.consumers, id: \.name) { consumer in
                    HStack(spacing: 6) {
                        Text(consumer.name == EnergyTally.vmName
                             ? HeaderMetric.vmEngine.title(engineName: engine.activeName)
                             : consumer.name).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 4)
                        Text("\(Int((consumer.share * 100).rounded()))%")
                            .monospacedDigit().foregroundStyle(.secondary)
                        Text(L10n.watts(consumer.averageWatts))
                            .monospacedDigit()
                            .frame(minWidth: 46, alignment: .trailing)
                    }
                    .padding(.leading, 8)
                }
            }
            .font(.caption)
            .padding(.top, 2)
        }
    }

    private func energyTitle(_ tally: EnergyTally) -> String {
        let since = tally.since.formatted(date: .omitted, time: .shortened)
        if !energy.isDischarging {
            return L10n.energyLastDischarge(since, tally.lastUpdate.formatted(date: .omitted, time: .shortened))
        }
        return tally.missedUnplug ? L10n.energySinceObserved(since) : L10n.energySince(since)
    }

    private func pressureLevelColor(_ level: MemoryPressureLevel) -> Color {
        switch level {
        case .normal: return .secondary
        case .warning: return .orange
        case .critical: return .red
        }
    }

    private func pressureColor(_ fraction: Double) -> Color {
        fraction < 0.70 ? .green : (fraction < 0.85 ? .yellow : .red)
    }

    private func clusterColor(_ level: ClusterHealthLevel) -> Color {
        switch level {
        case .healthy: return .green
        case .degraded: return .orange
        case .down: return .red
        case .unknown: return .gray
        }
    }

}
