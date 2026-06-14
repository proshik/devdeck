import SwiftUI

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

            Section(L10n.memoryMonitoringSection) {
                Toggle(L10n.vmMonitoringToggle, isOn: Binding(
                    get: { store.config.settings.vmMemoryMonitoring },
                    set: { store.setVMMonitoring($0) }
                ))
                Toggle(L10n.minikubeMonitoringToggle, isOn: Binding(
                    get: { store.config.settings.minikubeMemoryMonitoring },
                    set: { store.setMinikubeMonitoring($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.settings)
    }
}
