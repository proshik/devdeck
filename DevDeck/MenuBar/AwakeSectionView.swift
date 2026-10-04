import SwiftUI

struct AwakeSectionView: View {
    @Environment(AwakeModel.self) private var awake
    @State private var showingError = false

    var body: some View {
        @Bindable var awake = awake
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: awake.isActive ? "cup.and.saucer.fill" : "cup.and.saucer")
                    .foregroundStyle(awake.isActive ? Color.green : Color.secondary)
                Text(L10n.awakeTitle)
                Spacer()
                Button(awake.recovering && awake.isBusy ? L10n.awakeRecovery : (awake.isBusy ? L10n.awakeDisable : L10n.awakeEnable)) {
                    if awake.isBusy { awake.stop() } else { awake.start() }
                }
                .disabled(awake.stopping || (awake.recovering && awake.isBusy))
            }
            if awake.isBusy {
                Text(awake.stopping ? L10n.awakeStopping : (awake.isActive ? L10n.awakeActive : L10n.awakeStarting))
                    .foregroundStyle(.secondary)
            } else {
                Picker(L10n.awakeDuration, selection: $awake.durationSeconds) {
                    Text(L10n.awake30Minutes).tag(1800)
                    Text(L10n.awake1Hour).tag(3600)
                    Text(L10n.awake2Hours).tag(7200)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .accessibilityLabel(L10n.awakeDuration)
            }
            Text(L10n.awakeLimits).foregroundStyle(.secondary).font(.system(size: 10))
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
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .help(L10n.awakeDetails)
        .alert(L10n.awakeError, isPresented: $showingError) {
            Button(L10n.cancel, role: .cancel) {}
        } message: {
            Text(awake.error ?? L10n.awakeError)
        }
    }
}
