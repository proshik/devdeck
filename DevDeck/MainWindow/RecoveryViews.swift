import SwiftUI
import AppKit

/// "Recovery" group of the permissions page: what is switched off, why and since when, and the
/// explicit way back (REC-01).
struct RecoverySection: View {
    let model: RecoveryModel

    var body: some View {
        Section {
            if model.suspensions.isEmpty {
                Text(L10n.recoveryNothing).foregroundStyle(.secondary)
            }
            ForEach(model.suspensions) { entry in
                FormActionRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.recoveryModule(entry.module))
                        Text(L10n.recoveryReason(entry.suspension.reason, since: entry.suspension.since))
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } actions: {
                    Button(L10n.recoveryResume) { model.resume(entry.module) }
                }
            }
            FormActionRow {
                if model.suspensions.count > 1 {
                    Button(L10n.recoveryResumeAll) { model.resumeAll() }
                }
                Button(L10n.deckDiagnosticLog) {
                    NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.shared.fileURL])
                }
            }
        } header: {
            Text(L10n.recoverySection)
        } footer: {
            FormFooter(L10n.recoveryHelp)
        }
    }
}

/// One line above the panel and the window while any module is switched off.
struct RecoveryBanner: View {
    let model: RecoveryModel
    let show: () -> Void

    var body: some View {
        if model.hasSuspensions {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(L10n.recoveryBanner).font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button(L10n.recoveryShow, action: show).controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
            .accessibilityElement(children: .combine)
        }
    }
}
