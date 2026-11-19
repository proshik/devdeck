import SwiftUI

struct BrightnessDisplayRow: View {
    @Environment(DisplayBrightnessModel.self) private var model
    let display: BrightnessDisplay
    @State private var draft: Double?
    @State private var editing = false
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: display.builtIn ? "laptopcomputer" : "display").frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(display.name).lineLimit(1)
                    Text(display.method == .software ? L10n.brightnessSoftware : (display.builtIn ? L10n.brightnessBuiltIn : L10n.brightnessExternal))
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if model.pending[display.id] != nil {
                    ProgressView().controlSize(.mini).help(L10n.brightnessApplying)
                        .accessibilityLabel(L10n.brightnessApplying)
                }
                if let value = display.value {
                    Text(BrightnessLevelText.text(value: value, nits: model.nits(for: display)))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
            }
            if let value = display.value {
                HStack(spacing: 8) {
                    Image(systemName: "sun.min").foregroundStyle(.secondary)
                    Slider(value: Binding(get: { editing ? (draft ?? value) : (model.pending[display.id] ?? value) }, set: {
                        draft = $0; model.request(id: display.id, value: $0)
                    }), in: 0...1, onEditingChanged: {
                        editing = $0
                        if !$0 { draft = nil }
                    })
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .accessibilityLabel(L10n.brightnessTitle + ": " + display.name)
                    Image(systemName: "sun.max").foregroundStyle(.secondary)
                }.controlSize(.small)
            } else {
                Text(L10n.brightnessUnsupported).font(.caption).foregroundStyle(.secondary)
            }
            if let error = model.errors[display.id] { Text(error).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct BrightnessSectionView: View {
    @Environment(DisplayBrightnessModel.self) private var model
    @Environment(CommandStore.self) private var store
    var onDetails: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(L10n.brightnessTitle).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                Button(action: onDetails) { Image(systemName: "arrow.up.right").frame(width: 24, height: 24) }
                    .buttonStyle(.plain).controlHoverFeedback().help(L10n.deckDisplays)
            }
            if model.displays.isEmpty { Text(L10n.brightnessNoDisplays).foregroundStyle(.secondary) }
            ForEach(model.displays) { BrightnessDisplayRow(display: $0) }
            if model.displays.count > 1 {
                Toggle(L10n.brightnessLink, isOn: Binding(get: { store.config.settings.displays.linkSliders }, set: { value in store.updateDisplays { $0.linkSliders = value } }))
                    .toggleStyle(.switch).controlSize(.small)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }
}

struct DisplayBrightnessSettingsView: View {
    @Environment(DisplayBrightnessModel.self) private var model
    @Environment(CommandStore.self) private var store
    var body: some View {
        Form {
            Section(L10n.brightnessTitle) {
                if model.displays.isEmpty { Text(L10n.brightnessNoDisplays) }
                ForEach(model.displays) { display in
                    VStack(alignment: .leading, spacing: 12) {
                        BrightnessDisplayRow(display: display)
                        Picker(L10n.brightnessTitle, selection: Binding(get: { store.config.settings.displays.methods[display.id] ?? .hardware }, set: { value in
                            store.updateDisplays { $0.methods[display.id] = value }
                            Task { await model.refresh() }
                        })) {
                            ForEach(BrightnessMethod.allCases, id: \.self) { Text($0.title).tag($0) }
                        }.controlSize(.small)
                        if display.method == .hardware, display.hardwareMaximum != nil {
                            BrightnessLuminanceFields(display: display)
                        }
                    }.padding(.vertical, 6)
                }
                Toggle(L10n.brightnessLink, isOn: setting(\.linkSliders))
                Button(L10n.brightnessRefresh) { Task { await model.refresh() } }.disabled(model.refreshing)
            }
            Section(L10n.brightnessKeyboard) {
                Toggle(L10n.brightnessKeys, isOn: setting(\.keyboardEnabled))
                Toggle(L10n.brightnessLinkKeys, isOn: setting(\.linkKeys))
                    .disabled(!store.config.settings.displays.keyboardEnabled)
                Text(L10n.brightnessConflict).font(.caption).foregroundStyle(.secondary)
                if !model.keyboardStatus.isEmpty {
                    Text(model.keyboardStatus).foregroundStyle(.secondary)
                    Button(L10n.brightnessPermissionButton) { BrightnessKeys.requestPermission() }
                }
            }
            Section { Text(L10n.brightnessSoftwareHelp).font(.caption).foregroundStyle(.secondary) }
        }
        .formStyle(.grouped).navigationTitle(L10n.deckDisplays)
    }
    private func setting(_ keyPath: WritableKeyPath<DisplayBrightnessSettings, Bool>) -> Binding<Bool> {
        Binding(get: { store.config.settings.displays[keyPath: keyPath] }, set: { value in
            store.updateDisplays { $0[keyPath: keyPath] = value }
            model.updateKeyboard()
        })
    }
}

/// Per-display datasheet luminance for the ≈ nits estimate; empty fields use the model default.
struct BrightnessLuminanceFields: View {
    @Environment(CommandStore.self) private var store
    let display: BrightnessDisplay
    var body: some View {
        let fallback = BrightnessLuminance.defaults[BrightnessLuminance.key(vendor: display.edidVendor, product: display.edidProduct)]
        VStack(alignment: .leading, spacing: 6) {
            field(L10n.brightnessMaxNits, \.maximum, placeholder: fallback?.maximum)
            field(L10n.brightnessMinNits, \.minimum, placeholder: fallback?.minimum)
            Text(L10n.brightnessNitsHelp).font(.caption).foregroundStyle(.secondary)
        }.controlSize(.small)
    }
    private func field(_ title: String, _ keyPath: WritableKeyPath<BrightnessLuminanceRange, Double?>, placeholder: Double?) -> some View {
        let id = display.id
        return LabeledContent(title) {
            TextField(title, value: Binding(get: { store.config.settings.displays.luminance[id]?[keyPath: keyPath] }, set: { value in
                store.updateDisplays { settings in
                    var range = settings.luminance[id] ?? BrightnessLuminanceRange()
                    range[keyPath: keyPath] = value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
                    settings.luminance[id] = range.minimum == nil && range.maximum == nil ? nil : range
                }
            }), format: .number.precision(.fractionLength(0...1)),
            prompt: Text(placeholder.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "—"))
            .labelsHidden().multilineTextAlignment(.trailing).frame(width: 90)
        }
    }
}
