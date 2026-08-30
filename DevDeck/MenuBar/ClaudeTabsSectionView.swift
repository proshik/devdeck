import SwiftUI

/// The tray half of the feature: the same toggle as Settings, plus what the snapshot holds.
///
/// The popover is meant to stay minimal, so this is one toggle, one status line and two buttons —
/// the full list lives in the main window.
struct ClaudeTabsSectionView: View {
    @Environment(CommandStore.self) private var store
    @Environment(ClaudeTabsModel.self) private var claudeTabs
    @AppStorage("popover.section.claudeTabs.collapsed") private var collapsed = true

    var body: some View {
        CollapsibleSection(title: L10n.claudeTabsSection,
                           count: claudeTabs.snapshot?.tabs.count ?? 0,
                           runningCount: 0,
                           collapsed: $collapsed) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(L10n.claudeTabsRestoreToggle, isOn: Binding(
                    get: { store.config.settings.claudeTabsRestore },
                    set: { store.setClaudeTabsRestore($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button(L10n.claudeTabsCaptureNow) { claudeTabs.captureNow() }
                    Button(L10n.claudeTabsRestoreNow) { claudeTabs.restoreNow() }
                        .disabled((claudeTabs.snapshot?.tabs.isEmpty ?? true))
                }
                .buttonStyle(.link)
                .font(.caption)

                if let error = claudeTabs.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var stateText: String {
        guard let snapshot = claudeTabs.snapshot, !snapshot.tabs.isEmpty else {
            return L10n.claudeTabsNoSnapshot
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return L10n.claudeTabsSnapshotState(snapshot.tabs.count, formatter.string(from: snapshot.capturedAt))
    }
}
