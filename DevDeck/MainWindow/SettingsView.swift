import SwiftUI
import ServiceManagement

/// Global app settings (memory monitoring lives in config.json; language in UserDefaults).
struct SettingsView: View {
    @Environment(CommandStore.self) private var store
    @State private var localization = LocalizationManager.shared

    var body: some View {
        Form {
            Section(L10n.languageSection) {
                Picker(L10n.languagePicker, selection: $localization.language) {
                    ForEach(AppLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
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
