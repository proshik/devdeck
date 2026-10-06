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
            Section(L10n.deckPanel) {
                Button(L10n.deckPanelSettings) { appModel.selection = .panel }
            }
            Section("DevDeck") {
                LabeledContent(L10n.deckVersion, value: updates.currentVersion)
                Button(L10n.deckUpdates) { appModel.selection = .updates }
                Button(L10n.deckDiagnosticLog) {
                    NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.shared.fileURL])
                }
                if AppRuntime.isIsolated {
                    Text(L10n.deckIsolated).font(.caption).foregroundStyle(.secondary)
                }
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
                Text(updates.statusText).foregroundStyle(.secondary)
                if let checked = updates.lastCheckedAt {
                    LabeledContent(L10n.deckLastCheck, value: checked.formatted(date: .abbreviated, time: .shortened))
                }
                Button(L10n.checkForUpdates) { updates.checkForUpdatesUserInitiated() }
                    .disabled(AppRuntime.isIsolated || updates.isChecking)
            }
            Section(L10n.updatesSection) {
                Toggle(L10n.autoUpdateToggle, isOn: Binding(
                    get: { store.config.settings.autoUpdateEnabled },
                    set: {
                        store.setAutoUpdate($0)
                        if !AppRuntime.isIsolated { updates.setAutoUpdateEnabled($0) }
                    }
                ))
                if AppRuntime.isIsolated {
                    Text(L10n.deckDevelopmentUpdates).font(.caption).foregroundStyle(.secondary)
                }
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
            Section(section.title) { MonitoringMetricsView(section: section) }
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

struct PanelSettingsView: View {
    var body: some View {
        Form {
            Section(L10n.deckPanel) {
                Text(L10n.deckPanelDescription).foregroundStyle(.secondary)
            }
            Section(L10n.deckSection) {
                ForEach(PanelSection.allCases) { section in
                    LabeledContent {
                        Text(description(section)).foregroundStyle(.secondary)
                    } label: { Label(section.title, systemImage: section.symbol) }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.deckPanel)
    }

    private func description(_ section: PanelSection) -> String {
        switch section {
        case .environment: [L10n.commands, L10n.daemons, L10n.chains, L10n.deckPorts, L10n.proxy, L10n.claudeTabsSection].joined(separator: ", ")
        case .monitoring: MonitoringSection.allCases.map(\.title).joined(separator: ", ")
        case .displays: L10n.awakeTitle
        }
    }
}

struct AwakeSettingsView: View {
    var body: some View {
        Form {
            Section(L10n.awakeTitle) { AwakeSectionView() }
            Section { Text(L10n.awakeDetails).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.awakeTitle)
    }
}
