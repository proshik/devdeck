import SwiftUI
import UniformTypeIdentifiers

struct ClipboardSettingsView: View {
    @Environment(ClipboardModel.self) private var model
    @Environment(CommandStore.self) private var store
    @State private var bundleID = ""
    var body: some View {
        Form {
            Section(L10n.clipboardCollection) {
                Toggle(L10n.clipboardEnabled, isOn: setting(\.enabled))
                Toggle(L10n.clipboardPause, isOn: setting(\.paused)).disabled(!store.config.settings.clipboard.enabled)
                if (store.config.settings.clipboard.enabled && model.access != .allowed) || model.errorMessage != nil {
                    ClipboardStatusView()
                }
                Text(L10n.clipboardPrivacyHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.clipboardPaste) {
                Toggle(L10n.clipboardPasteEnabled, isOn: Binding(get: { store.config.settings.clipboard.pasteEnabled }, set: { value in
                    store.updateClipboard { $0.pasteEnabled = value }
                    if value { model.requestPastePermission() }
                }))
                if store.config.settings.clipboard.pasteEnabled && !model.pastePermission {
                    Text(L10n.clipboardPastePermission).font(.caption).foregroundStyle(.secondary)
                    Button(L10n.clipboardPasteRequest) { model.requestPastePermission() }
                }
                Text(L10n.clipboardPasteHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.clipboardRetention) {
                Stepper(L10n.clipboardCountLimit + ": \(store.config.settings.clipboard.maxEntries)", value: setting(\.maxEntries), in: 100...10_000, step: 100)
                Stepper(L10n.clipboardDaysLimit + ": \(store.config.settings.clipboard.retentionDays)", value: setting(\.retentionDays), in: 1...365)
                Stepper(L10n.clipboardBytesLimit + ": \(store.config.settings.clipboard.maxBytes / 1_024 / 1_024)", value: Binding(
                    get: { store.config.settings.clipboard.maxBytes / 1_024 / 1_024 },
                    set: { value in store.updateClipboard { $0.maxBytes = value * 1_024 * 1_024 } }), in: 1...100)
                Text(L10n.clipboardLimitsHelp + " " + L10n.clipboardMediaLimitsHelp).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.clipboardExclusions) {
                ForEach(store.config.settings.clipboard.excludedBundleIDs, id: \.self) { id in
                    HStack {
                        Text(id).textSelection(.enabled).lineLimit(1).truncationMode(.middle).help(id)
                        Spacer()
                        Button { store.updateClipboard { $0.excludedBundleIDs.removeAll { $0 == id } } } label: {
                            Image(systemName: "minus.circle")
                        }.buttonStyle(.borderless).controlHoverFeedback().help(L10n.clipboardRemoveExclusion)
                            .accessibilityLabel(L10n.clipboardRemoveExclusion)
                    }
                }
                HStack {
                    TextField(L10n.clipboardBundleID, text: $bundleID)
                    Button(L10n.deckAdd) { addExclusion(bundleID); bundleID = "" }
                        .disabled(bundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button(L10n.clipboardAddApp) { chooseExcludedApplication() }
                }
            }
        }.formStyle(.grouped)
    }
    private func setting<Value>(_ key: WritableKeyPath<ClipboardSettings, Value>) -> Binding<Value> {
        Binding(get: { store.config.settings.clipboard[keyPath: key] },
                set: { value in store.updateClipboard { $0[keyPath: key] = value } })
    }
    private func addExclusion(_ rawID: String) {
        let id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        store.updateClipboard { if !$0.excludedBundleIDs.contains(id) { $0.excludedBundleIDs.append(id) } }
    }
    private func chooseExcludedApplication() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.applicationBundle]; panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false; panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.begin { response in
            guard response == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
            addExclusion(id)
        }
    }
}
