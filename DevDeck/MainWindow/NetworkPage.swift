import SwiftUI
import Charts

struct NetworkMetricsView: View {
    @Environment(DeckMonitoringModel.self) private var monitoring
    @Environment(CommandStore.self) private var store
    @State private var reader = UUID()
    var onDetails: (() -> Void)?
    private var model: NetworkMonitoringModel { monitoring.network }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(L10n.networkTraffic, systemImage: "network").fontWeight(.medium)
                Spacer(minLength: 0)
                if let onDetails {
                    Button(action: onDetails) { Image(systemName: "arrow.up.forward") }
                        .buttonStyle(.borderless).help(L10n.networkTitle).accessibilityLabel(L10n.networkTitle)
                }
            }
            Picker(L10n.networkInterface, selection: Binding(get: { store.config.settings.monitoring.networkInterface ?? "" }, set: { id in
                store.updateMonitoring { $0.networkInterface = id.isEmpty ? nil : id }
            })) {
                Text(L10n.networkAutomatic).tag("")
                ForEach(model.interfaces) { Text($0.name).tag($0.id) }
                if let id = store.config.settings.monitoring.networkInterface, !model.interfaces.contains(where: { $0.id == id }) {
                    Text(id + " · " + L10n.monitoringUnavailable).tag(id)
                }
            }
            if store.config.settings.monitoring.networkInterface == nil {
                Text(L10n.networkSource(model.source?.name ?? L10n.monitoringUnavailable))
                    .font(.caption).foregroundStyle(.secondary)
            }
            trafficRow(L10n.networkReceive, model.point.map { L10n.networkBytes($0.received, rate: true) })
            trafficRow(L10n.networkSend, model.point.map { L10n.networkBytes($0.sent, rate: true) })
            Text(L10n.networkSession).font(.caption).foregroundStyle(.secondary)
            Text(model.measuredAt == nil ? "—" : "↓ " + L10n.networkBytes(Double(model.totals.received)) + " · ↑ " + L10n.networkBytes(Double(model.totals.sent))).monospacedDigit()
            Chart(model.history) { point in
                LineMark(x: .value("Time", point.date), y: .value(L10n.networkRateUnit, point.received)).foregroundStyle(by: .value("Direction", L10n.networkReceive))
                LineMark(x: .value("Time", point.date), y: .value(L10n.networkRateUnit, point.sent)).foregroundStyle(by: .value("Direction", L10n.networkSend))
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: onDetails == nil ? 5 : 2)) }
            .chartYAxis {
                AxisMarks(values: .automatic(desiredCount: onDetails == nil ? 4 : 2)) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let bytes = value.as(Double.self) {
                            Text(L10n.networkBytes(bytes, rate: true)).font(.caption2)
                        }
                    }
                }
            }
            .frame(height: onDetails == nil ? 150 : 90)
            if let date = model.measuredAt {
                Text((model.collecting ? L10n.monitoringUpdated : L10n.monitoringLast) + ": " + date.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary)
            } else { Text(L10n.monitoringUnavailable).font(.caption).foregroundStyle(.secondary) }
            if !model.collecting { Text(L10n.deckCollectionOff).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear { model.begin(reader) }
        .onDisappear { model.end(reader) }
    }
    private func trafficRow(_ title: String, _ value: String?) -> some View {
        HStack { Text(title).foregroundStyle(.secondary); Spacer(); Text(value ?? "—").monospacedDigit() }
    }
}
struct NetworkPage: View {
    @Environment(DeckMonitoringModel.self) private var monitoring
    @Environment(CommandStore.self) private var store
    private var model: NetworkMonitoringModel { monitoring.network }
    var body: some View {
        Form {
            // The page title already names the metrics; their group needs no header of its own.
            Section { NetworkMetricsView() }
            Section {
                Toggle(L10n.networkCollect, isOn: Binding(get: { store.config.settings.monitoring.networkEnabled }, set: { value in store.updateMonitoring { $0.networkEnabled = value } }))
                Toggle(L10n.monitoringEnabled, isOn: Binding(get: { store.config.settings.monitoring.enabled }, set: { value in store.updateMonitoring { $0.enabled = value } }))
                Stepper(L10n.monitoringInterval + ": \(store.config.settings.monitoring.interval)", value: Binding(get: { store.config.settings.monitoring.interval }, set: { value in store.updateMonitoring { $0.intervalSeconds = value } }), in: 1...60)
                Toggle(L10n.monitoringHistory, isOn: Binding(get: { store.config.settings.monitoring.historyEnabled }, set: { value in store.updateMonitoring { $0.historyEnabled = value } }))
            } header: {
                Text(L10n.monitoringCollectionSection)
            } footer: {
                FormFooter(L10n.monitoringHistoryHelp)
            }
            Section {
                FormActionRow {
                    if model.runningTest {
                        ProgressView().controlSize(.small)
                        Text(L10n.networkRunning).foregroundStyle(.secondary)
                    }
                } actions: {
                    if model.runningTest { Button(L10n.cancel) { model.cancelTest() } }
                    else { Button(L10n.networkTest) { model.runTest() } }
                }
                if let error = model.failure { Text(L10n.networkError(error)).foregroundStyle(.secondary) }
                if let result = model.result {
                    LabeledContent(L10n.monitoringLast, value: result.date.formatted())
                    LabeledContent(L10n.networkInterface, value: result.interface ?? L10n.monitoringUnavailable)
                    LabeledContent(L10n.networkCapacity, value: String(format: "%.2f / %.2f", result.download / 1e6, result.upload / 1e6))
                    LabeledContent(L10n.networkResponsiveness, value: result.responsiveness.map { String(format: "%.0f", $0) } ?? "—")
                    LabeledContent(L10n.networkLatency, value: result.latency.map { String(format: "%.1f", $0) } ?? "—")
                }
            } header: {
                Text(L10n.networkTest)
            } footer: {
                FormFooter(L10n.networkTestHelp)
            }
        }.formStyle(.grouped)
        .navigationTitle(L10n.networkTitle)
    }
}
