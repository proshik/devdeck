import SwiftUI

struct AwakeSectionView: View {
    @Environment(AwakeModel.self) private var awake
    @State private var showingError = false
    var compact = false
    var onDetails: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Label {
                    Text(L10n.awakeTitle)
                } icon: {
                    Image(systemName: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                        .foregroundStyle(awake.isActive ? Color.green : Color.secondary)
                }.labelStyle(DeckLabelStyle())
                Spacer()
                Button(awake.recovering && awake.isBusy ? L10n.awakeRecovery : (awake.isBusy ? L10n.awakeDisable : L10n.awakeEnable)) {
                    if awake.isBusy { awake.stop() } else { awake.start() }
                }
                .disabled(awake.stopping || (awake.recovering && awake.isBusy))
                .controlSize(compact ? .small : .regular)
                if let onDetails {
                    Button(action: onDetails) {
                        Label(L10n.awakeTitle, systemImage: "arrow.up.forward")
                            .labelStyle(.iconOnly).frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless).controlHoverFeedback()
                    .foregroundStyle(.secondary).help(L10n.awakeDetails)
                }
            }
            if awake.isBusy {
                Text(awake.stopping ? L10n.awakeStopping : (awake.isActive ? L10n.awakeActive : L10n.awakeStarting))
                    .foregroundStyle(.secondary)
                    .font(compact ? .caption : .body)
            } else {
                if compact {
                    HStack {
                        Text(L10n.awakeDuration).font(.caption).foregroundStyle(.secondary)
                        Spacer(minLength: 8)
                        durationPicker.pickerStyle(.menu).controlSize(.small).fixedSize()
                    }.padding(.leading, 28).padding(.trailing, onDetails == nil ? 0 : 36)
                } else {
                    durationPicker.pickerStyle(.segmented)
                }
            }
            if !compact { Text(L10n.awakeLimits).foregroundStyle(.secondary).font(.system(size: 10)) }
            if awake.recoveryAvailable {
                Button(L10n.awakeRecovery) { awake.start(recovery: true) }
                    .help(L10n.awakeRecoveryHelp)
            }
            if awake.thermalStop {
                Text(L10n.awakeThermalStop).foregroundStyle(.orange)
            }
            if awake.error != nil {
                Button(L10n.awakeError) { showingError = true }.foregroundStyle(.red)
            }
        }
        .font(compact ? .body : .system(size: 11))
        .padding(.horizontal, 16)
        .padding(.vertical, compact ? 10 : 9)
        .help(L10n.awakeDetails + "\n" + L10n.awakeLimits)
        .alert(L10n.awakeError, isPresented: $showingError) {
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(awake.error ?? L10n.awakeError)
        }
    }

    private var durationPicker: some View {
        @Bindable var awake = awake
        return Picker(L10n.awakeDuration, selection: $awake.durationSeconds) {
            Text(L10n.awake30Minutes).tag(1800)
            Text(L10n.awake1Hour).tag(3600)
            Text(L10n.awake2Hours).tag(7200)
            Text(L10n.awakeIndefinite).tag(0)
        }
        .labelsHidden()
        .accessibilityLabel(L10n.awakeDuration)
    }
}
