import SwiftUI
import ServiceManagement

/// Global app settings (memory monitoring lives in config.json; language in UserDefaults).
struct SettingsView: View {
    @Environment(CommandStore.self) private var store
    @Environment(UpdateController.self) private var updates
    @State private var localization = LocalizationManager.shared
    @State private var appearance = AppearanceManager.shared

    var body: some View {
        Form {
            Section(L10n.languageSection) {
                Picker(L10n.languagePicker, selection: $localization.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
            }

            Section(L10n.appearanceSection) {
                Picker(L10n.appearancePicker, selection: $appearance.appearance) {
                    ForEach(AppAppearance.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section(L10n.startupSection) {
                Toggle(L10n.launchAtLoginToggle, isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { setLaunchAtLogin($0) }
                ))
                Toggle(L10n.globalHotkeyToggle, isOn: Binding(
                    get: { store.config.settings.globalHotkeyEnabled },
                    set: {
                        store.setGlobalHotkey($0)
                        HotKeyManager.shared.setEnabled($0)
                    }
                ))
            }

            Section(L10n.memoryMonitoringSection) {
                Toggle(L10n.vmMonitoringToggle, isOn: Binding(
                    get: { store.config.settings.vmMemoryMonitoring },
                    set: { store.setVMMonitoring($0) }
                ))
                Toggle(L10n.minikubeMonitoringToggle, isOn: Binding(
                    get: { store.config.settings.minikubeMemoryMonitoring },
                    set: { store.setMinikubeMonitoring($0) }
                ))
                Toggle(L10n.hostMonitoringToggle, isOn: Binding(
                    get: { store.config.settings.hostMemoryMonitoring },
                    set: { store.setHostMonitoring($0) }
                ))
                Toggle(L10n.clusterHealthToggle, isOn: Binding(
                    get: { store.config.settings.clusterHealthMonitoring },
                    set: { store.setClusterHealth($0) }
                ))
            }

            Section(L10n.updatesSection) {
                Toggle(L10n.autoUpdateToggle, isOn: Binding(
                    get: { store.config.settings.autoUpdateEnabled },
                    set: {
                        store.setAutoUpdate($0)
                        updates.setAutoUpdateEnabled($0)
                    }
                ))
                HStack {
                    if updates.updateAvailable, let latest = updates.latestVersion {
                        Text(L10n.updateAvailableRow(updates.currentVersion, latest, behind: updates.releasesBehind))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(L10n.upToDate).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(L10n.checkForUpdates) { updates.checkForUpdatesUserInitiated() }
                }
                .font(.callout)
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.settings)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            DiagnosticLog.shared.log("Launch-at-login toggle failed: \(error.localizedDescription)", level: .warn)
        }
    }
}
