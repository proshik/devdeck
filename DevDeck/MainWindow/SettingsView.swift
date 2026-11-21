import SwiftUI
import ServiceManagement

/// General application preferences. Functional settings live on their own pages.
struct SettingsView: View {
    @Environment(CommandStore.self) private var store
    @Environment(UpdateController.self) private var updates
    @Environment(AppModel.self) private var appModel
    @State private var localization = LocalizationManager.shared
    @State private var appearance = AppearanceManager.shared
    @State private var startupError: String?
    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        Form {
            Section(L10n.appearanceSection) {
                Picker(L10n.languagePicker, selection: $localization.language) {
                    ForEach(AppLanguage.allCases) { Text($0.displayName).tag($0) }
                }
                Picker(L10n.appearancePicker, selection: $appearance.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.displayName).tag($0) }
                }.pickerStyle(.segmented)
            }
            Section(L10n.startupSection) {
                Toggle(L10n.launchAtLoginToggle, isOn: Binding(
                    get: { loginStatus == .enabled }, set: { setLaunchAtLogin($0) }
                )).disabled(AppRuntime.isIsolated)
                Toggle(L10n.globalHotkeyToggle, isOn: Binding(
                    get: { store.config.settings.globalHotkeyEnabled },
                    set: {
                        store.setGlobalHotkey($0)
                        if !AppRuntime.isIsolated { HotKeyManager.shared.setEnabled($0) }
                    }
                ))
                if let startupError {
                    Label(startupError, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            Section {
                Toggle(L10n.automationToggle, isOn: Binding(
                    get: { store.config.settings.automationEnabled },
                    set: { store.setAutomationEnabled($0) }
                ))
            } header: {
                Text(L10n.automationSection)
            } footer: {
                FormFooter(L10n.automationHelp)
            }
            Section {
                LabeledContent(L10n.deckVersion, value: updates.currentVersion)
                FormNavigationRow(title: L10n.deckPanel) { appModel.selection = .panel }
                FormNavigationRow(title: L10n.deckUpdates) { appModel.selection = .updates }
                FormActionRow {
                    Button(L10n.deckDiagnosticLog) {
                        NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.shared.fileURL])
                    }
                }
            } header: {
                Text("DevDeck")
            } footer: {
                if AppRuntime.isIsolated { FormFooter(L10n.deckIsolated) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.deckGeneral)
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        startupError = nil
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            startupError = L10n.deckLoginError + ": " + error.localizedDescription
            DiagnosticLog.shared.log("Launch-at-login toggle failed: \(error.localizedDescription)", level: .warn)
        }
        loginStatus = SMAppService.mainApp.status
    }
}

struct UpdatesView: View {
    @Environment(CommandStore.self) private var store
    @Environment(UpdateController.self) private var updates

    var body: some View {
        Form {
            Section("DevDeck") {
                LabeledContent(L10n.deckVersion, value: updates.currentVersion)
                if let checked = updates.lastCheckedAt {
                    LabeledContent(L10n.deckLastCheck, value: AppDateFormat.string(checked, date: .abbreviated, time: .shortened))
                }
                FormActionRow {
                    Text(updates.statusText).foregroundStyle(.secondary)
                } actions: {
                    Button(L10n.checkForUpdates) { updates.checkForUpdatesUserInitiated() }
                        .disabled(AppRuntime.isIsolated || updates.isChecking)
                }
            }
            Section {
                Toggle(L10n.autoUpdateToggle, isOn: Binding(
                    get: { store.config.settings.autoUpdateEnabled },
                    set: {
                        store.setAutoUpdate($0)
                        if !AppRuntime.isIsolated { updates.setAutoUpdateEnabled($0) }
                    }
                ))
            } header: {
                Text(L10n.updatesSection)
            } footer: {
                if AppRuntime.isIsolated { FormFooter(L10n.deckDevelopmentUpdates) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.deckUpdates)
    }
}

struct MonitoringPage: View {
    @Environment(CommandStore.self) private var store
    @Environment(EngineModel.self) private var engine
    @Environment(DeckMonitoringModel.self) private var monitoring
    let section: MonitoringSection
    @State private var reader = UUID()

    var body: some View {
        Form {
            // The page title already names the metrics; their group needs no header of its own.
            Section { MonitoringMetricsView(section: section) }
            Section(L10n.monitoringHistoryTitle) { MonitoringHistoryView(section: section) }
            Section {
                Toggle(L10n.monitoringEnabled, isOn: Binding(
                    get: { store.config.settings.monitoring.enabled },
                    set: { value in store.updateMonitoring { $0.enabled = value } }))
                Stepper(L10n.monitoringInterval + ": \(store.config.settings.monitoring.interval)", value: Binding(
                    get: { store.config.settings.monitoring.interval },
                    set: { value in store.updateMonitoring { $0.intervalSeconds = value } }), in: 1...60)
                Toggle(L10n.monitoringHistory, isOn: Binding(
                    get: { store.config.settings.monitoring.historyEnabled },
                    set: { value in store.updateMonitoring { $0.historyEnabled = value } }))
            } header: {
                Text(L10n.monitoringCollectionSection)
            } footer: {
                FormFooter(L10n.monitoringHistoryHelp)
            }
            Section(L10n.memoryMonitoringSection) {
                switch section {
                case .mac:
                    Toggle(L10n.hostMonitoringToggle, isOn: Binding(
                        get: { store.config.settings.hostMemoryMonitoring }, set: { store.setHostMonitoring($0) }
                    ))
                case .containers:
                    Picker(L10n.containerEnginePicker, selection: Binding(
                        get: { store.config.settings.containerEngine }, set: { store.setContainerEngine($0) }
                    )) {
                        ForEach(EnginePreference.allCases, id: \.self) { Text(L10n.containerEngineOption($0)).tag($0) }
                    }
                    Toggle(L10n.vmMonitoringToggle(engineName: engine.activeName), isOn: Binding(
                        get: { store.config.settings.vmMemoryMonitoring }, set: { store.setVMMonitoring($0) }
                    ))
                    Toggle(L10n.minikubeMonitoringToggle, isOn: Binding(
                        get: { store.config.settings.minikubeMemoryMonitoring }, set: { store.setMinikubeMonitoring($0) }
                    ))
                    Toggle(L10n.clusterHealthToggle(engineName: engine.activeName), isOn: Binding(
                        get: { store.config.settings.clusterHealthMonitoring }, set: { store.setClusterHealth($0) }
                    ))
                case .energy:
                    Toggle(L10n.batteryMonitoringToggle, isOn: Binding(
                        get: { store.config.settings.batteryMonitoring }, set: { store.setBatteryMonitoring($0) }
                    ))
                }
            }
            Section(L10n.metricsHelpTitle) {
                ForEach(helpMetrics, id: \.self) { metric in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(metric.title(engineName: engine.activeName)).fontWeight(.medium)
                        Text(metric.help).font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 2)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(section.title)
        .onAppear { monitoring.begin(reader) }
        .onDisappear { monitoring.end(reader) }
    }

    private var helpMetrics: [HeaderMetric] {
        switch section {
        case .mac: [.memory, .swap, .pressure, .swapRate, .cpuLoad]
        case .containers: [.vmEngine, .vmMinikube, .diskVM, .cluster]
        case .energy: [.battery]
        }
    }
}

struct AwakeSettingsView: View {
    var body: some View {
        Form {
            // The page title already says what this is; the explanation belongs under the group.
            Section { AwakeSectionView() } footer: { FormFooter(L10n.awakeDetails) }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.awakeTitle)
    }
}
