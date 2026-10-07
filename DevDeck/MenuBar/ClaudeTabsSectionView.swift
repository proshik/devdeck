import SwiftUI

/// Snapshot summary. Preferences, capture and restore actions live on the agent tabs page.
struct ClaudeTabsSectionView: View {
    @Environment(CommandStore.self) private var store
    @Environment(ClaudeTabsModel.self) private var claudeTabs
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    private var enabled: Bool { store.config.settings.claudeTabsRestore }
    private var tabCount: Int { claudeTabs.snapshot?.tabs.count ?? 0 }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Label(tabCount > 0 ? L10n.deckSavedTabs(tabCount) : L10n.claudeTabsSection,
                      systemImage: "macwindow.on.rectangle")
                    .lineLimit(1).layoutPriority(1)
                Spacer(minLength: 4)
                Text(stateText).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).monospacedDigit()
                Button {
                    appModel.showMainWindow(selection: .claudeTabs) {
                        openWindow(id: "main")
                        NSApp.activate()
                    }
                } label: {
                    Label(L10n.claudeTabsSection, systemImage: "arrow.up.forward")
                        .labelStyle(.iconOnly).frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless).controlHoverFeedback()
                .foregroundStyle(.secondary)
                .help(L10n.claudeTabsSection)
            }
            if let error = claudeTabs.lastError {
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange).lineLimit(2)
            }
        }.padding(.horizontal, 16).padding(.vertical, 10)
    }

    private var stateText: String {
        guard enabled else { return L10n.deckSessionsDisabled }
        guard let snapshot = claudeTabs.snapshot, !snapshot.tabs.isEmpty else {
            return L10n.claudeTabsNoSnapshot
        }
        // Include the date for older snapshots, so a pre-reboot copy cannot look freshly saved.
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(snapshot.capturedAt) ? .none : .short
        return formatter.string(from: snapshot.capturedAt)
    }
}
