import SwiftUI

/// The full snapshot: which tabs would come back, and which of them we could tie to a session.
/// A row without a session still restores — as a shell in its directory — and saying so here is
/// what keeps that from looking like a bug.
struct ClaudeTabsView: View {
    @Environment(ClaudeTabsModel.self) private var claudeTabs

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(L10n.claudeTabsCaptureNow) { claudeTabs.captureNow() }
                Button(L10n.claudeTabsRestoreNow) { claudeTabs.restoreNow() }
                    .disabled(claudeTabs.snapshot?.tabs.isEmpty ?? true)
            }

            if let entries = claudeTabs.snapshot?.tabs, !entries.isEmpty {
                Table(entries) {
                    TableColumn("#") { Text("\($0.order + 1)") }.width(24)
                    TableColumn(L10n.claudeTabsColumnTitle) { Text($0.title) }
                    TableColumn(L10n.claudeTabsColumnDirectory) {
                        Text($0.workingDirectory).foregroundStyle(.secondary)
                    }
                    TableColumn(L10n.claudeTabsColumnSession) { entry in
                        Text(entry.sessionID == nil ? L10n.claudeTabsDirectoryOnly : L10n.claudeTabsSessionFound)
                            .foregroundStyle(entry.sessionID == nil ? .secondary : .primary)
                    }
                }
            } else {
                Text(L10n.claudeTabsNoSnapshot).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
