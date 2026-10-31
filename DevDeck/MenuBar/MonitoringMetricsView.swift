import SwiftUI

/// Rendering reads only the shared snapshot; no kernel reads, CLI probes or view-owned timers.
struct MonitoringMetricsView: View {
    @Environment(DeckMonitoringModel.self) private var monitoring
    let section: MonitoringSection
    var compact = false
    var onDetails: (() -> Void)? = nil

    private var enabled: Bool {
        monitoring.context.settings.enabled && !monitoring.suspended && {
            switch section {
            case .mac: true
            case .energy: monitoring.context.batteryEnabled
            case .containers: monitoring.context.vmEnabled || monitoring.context.minikubeEnabled || monitoring.context.clusterEnabled
            }
        }()
    }
    private var measuredAt: Date? {
        switch section {
        case .mac: monitoring.snapshot.mac?.date
        case .containers: monitoring.snapshot.containers?.date
        case .energy: monitoring.snapshot.energy?.date
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            switch section {
            case .mac: mac
            case .containers: containers
            case .energy: energy
            }
            HStack {
                if let measuredAt {
                    Text((enabled ? L10n.monitoringUpdated : L10n.monitoringLast) + ": "
                         + measuredAt.formatted(date: .omitted, time: .standard))
                } else { Text(L10n.deckNoData) }
                Spacer(minLength: 0)
                if let onDetails {
                    Button(action: onDetails) { Image(systemName: "arrow.up.forward") }
                        .buttonStyle(.borderless).help(section.title)
                }
            }.font(.caption).foregroundStyle(.secondary)
            if !enabled { Text(L10n.deckCollectionOff).font(.caption).foregroundStyle(.secondary) }
        }
    }

    @ViewBuilder private var mac: some View {
        let value = monitoring.snapshot.mac?.value
        row(L10n.monitoringCPU, value?.cpuBusyPercent.map { String(format: "%.1f%%", $0) }, "cpu")
        row(L10n.monitoringLoad, value?.sample.loadAverage.map { String(format: "%.2f", $0) }, "waveform.path.ecg")
        if monitoring.context.hostEnabled {
            row(L10n.memory, value?.sample.memory.map { SystemMemory.format(usedBytes: $0.usedBytes, totalBytes: $0.totalBytes) }, "memorychip")
            row(HeaderMetric.pressure.title(engineName: nil), value?.sample.host.flatMap {
                $0.pressureAvailable ? L10n.pressureValue($0.pressure) : nil
            }, "gauge.with.dots.needle.33percent")
            row(HeaderMetric.swap.title(engineName: nil), value?.sample.memory.flatMap {
                $0.swapAvailable ? SystemMemory.formatGiB($0.swapUsedBytes) : nil
            }, "internaldrive")
            row(HeaderMetric.swapRate.title(engineName: nil), swapRate(value), "arrow.up.arrow.down")
        } else { Text(L10n.monitoringMemoryOff).font(.caption).foregroundStyle(.secondary) }
        row(L10n.monitoringDisk, disk(value?.sample), "internaldrive")
        row(L10n.monitoringUptime, value?.sample.uptime.map(L10n.monitoringUptimeValue), "clock")
        if !compact {
            row("GPU", nil, "cpu", reason: L10n.monitoringUnsupported)
            row(L10n.monitoringTemperature, nil, "thermometer", reason: L10n.monitoringUnsupported)
            Text(L10n.monitoringUnsupported).font(.caption).foregroundStyle(.secondary)
        }
    }
    @ViewBuilder private var containers: some View {
        let value = monitoring.snapshot.containers?.value
        let name = value?.engineName
        row(name ?? L10n.deckContainers, value.map { $0.running ? L10n.deckEngineRunning : L10n.deckEngineStopped }, "shippingbox")
        row(HeaderMetric.vmEngine.title(engineName: name), value?.vm?.format(), "memorychip")
        row(HeaderMetric.vmMinikube.title(engineName: name), value?.minikube?.format(), "memorychip")
        row(HeaderMetric.diskVM.title(engineName: name), value?.disk?.format(), "internaldrive")
        if value?.disk != nil, let date = value?.diskMeasuredAt {
            Text(HeaderMetric.diskVM.title(engineName: name) + " · " + L10n.monitoringUpdated + ": "
                 + date.formatted(date: .omitted, time: .standard))
                .font(.caption2).foregroundStyle(.secondary)
        }
        row(HeaderMetric.cluster.title(engineName: name), value?.cluster.map { L10n.clusterHealthValue($0.level) }, "server.rack")
    }
    @ViewBuilder private var energy: some View {
        let value = monitoring.snapshot.energy?.value
        row(HeaderMetric.battery.title(engineName: nil), value?.battery?.format(), "battery.100percent")
        if !compact {
            row(L10n.monitoringCycles, value?.details.cycles.map(String.init), "arrow.trianglehead.2.clockwise.rotate.90")
            row(L10n.monitoringHealth, value?.details.health, "heart")
            row(L10n.monitoringAdapter, value?.details.adapterWatts.map(L10n.watts), "powerplug")
            row(L10n.monitoringBatteryPower, value?.details.batteryWatts.map { ($0 >= 0 ? "+" : "") + L10n.watts($0) }, "bolt")
            Text(L10n.monitoringPowerHelp).font(.caption).foregroundStyle(.secondary)
        }
        if let value, let tally = value.tally {
            Text(L10n.monitoringEnergyShare).font(.caption).foregroundStyle(.secondary)
            ForEach(compact ? Array(value.consumers.prefix(3)) : value.consumers, id: \.name) { consumer in
                HStack {
                    Text(consumer.name).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text(String(format: "%.0f%% · ", consumer.share * 100) + L10n.watts(consumer.averageWatts)).monospacedDigit()
                }.font(.caption)
            }
            if value.consumers.isEmpty { Text(L10n.energyNoData).font(.caption).foregroundStyle(.secondary) }
            if !compact {
                Text(value.isDischarging
                     ? L10n.energySince(tally.since.formatted(date: .omitted, time: .shortened))
                     : L10n.energyLastDischarge(tally.since.formatted(date: .omitted, time: .shortened),
                                               tally.lastUpdate.formatted(date: .omitted, time: .shortened)))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func row(_ title: String, _ value: String?, _ symbol: String, reason: String = L10n.monitoringMissing) -> some View {
        HStack(spacing: 8) {
            Label(title, systemImage: symbol).foregroundStyle(.secondary)
            Spacer(minLength: 4)
            Text(value ?? "—").monospacedDigit().lineLimit(1).minimumScaleFactor(0.8)
        }.frame(minHeight: 23).help(value == nil ? reason : title)
            .accessibilityElement(children: .combine)
            .accessibilityValue(value ?? (L10n.monitoringUnavailable + ": " + reason))
    }
    private func swapRate(_ value: MacMonitoringValues?) -> String? {
        guard let input = value?.swapInBytesPerSecond, let output = value?.swapOutBytesPerSecond else { return nil }
        return L10n.monitoringSwapRate(input: input, output: output)
    }
    private func disk(_ sample: MacMonitoringSample?) -> String? {
        guard let used = sample?.diskUsedBytes, let total = sample?.diskTotalBytes else { return nil }
        return L10n.monitoringDiskValue(used: used, total: total)
    }
}
