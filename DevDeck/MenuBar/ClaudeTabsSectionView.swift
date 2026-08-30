import SwiftUI

/// Popover block for the Claude Code tab snapshots.
///
/// Written in the deck's own vocabulary rather than SwiftUI's: the on/off is a `DeckRow`, the same
/// control the proxy share row beside it uses, and the state and actions are note lines at the
/// deck's own indent. The first version used a `Toggle` with its own padding and link buttons —
/// the only switch control in the entire popover, and it read as if pasted in from another app.
struct ClaudeTabsSectionView: View {
    @Environment(CommandStore.self) private var store
    @Environment(ClaudeTabsModel.self) private var claudeTabs
    @Environment(AppModel.self) private var appModel
    @Environment(\.openWindow) private var openWindow

    @AppStorage("popover.section.claudeTabs.collapsed") private var collapsed = true

    private var enabled: Bool { store.config.settings.claudeTabsRestore }
    private var tabCount: Int { claudeTabs.snapshot?.tabs.count ?? 0 }

    var body: some View {
        CollapsibleSection(title: L10n.claudeTabsSection,
                           count: tabCount,
                           runningCount: enabled && tabCount > 0 ? tabCount : 0,
                           collapsed: $collapsed) {
            DeckRow(name: L10n.claudeTabsRestoreToggle,
                    needsSudo: false,
                    indicator: indicator,
                    onToggle: { store.setClaudeTabsRestore(!enabled) },
                    onLogs: { openPage() })

            if enabled {
                note(stateText, icon: "clock.arrow.circlepath", color: .secondary)
                action(L10n.claudeTabsCaptureNow, icon: "camera") { captureNow() }
                if tabCount > 0 {
                    action(L10n.claudeTabsRestoreNow, icon: "arrow.uturn.backward") {
                        claudeTabs.restoreNow()
                    }
                }
            }

            if let error = claudeTabs.lastError {
                note(error, icon: "exclamationmark.triangle.fill", color: .orange)
            }
        }
    }

    /// Green only once the feature is on AND actually holding something: an armed feature with an
    /// empty snapshot is not a working one, and green in this deck means "running". `isStop`
    /// follows the same rule as every other row — ■ when there is something to switch off.
    private var indicator: DeckIndicator {
        if claudeTabs.lastError != nil {
            return DeckIndicator(status: .failed, isStop: enabled)
        }
        guard enabled else { return DeckIndicator(status: .idle, isStop: false) }
        return DeckIndicator(status: tabCount > 0 ? .daemon : .idle, isStop: true)
    }

    /// Shows the DATE as soon as the snapshot is not from today.
    ///
    /// Time alone made a snapshot from before the last restart read as "18:42" — indistinguishable
    /// from one taken minutes ago, which is exactly the moment the difference matters, because
    /// pressing "capture now" then overwrites the only copy of the pre-reboot tabs.
    private var stateText: String {
        guard let snapshot = claudeTabs.snapshot, !snapshot.tabs.isEmpty else {
            return L10n.claudeTabsNoSnapshot
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = Calendar.current.isDateInToday(snapshot.capturedAt) ? .none : .short
        return L10n.claudeTabsSnapshotState(snapshot.tabs.count,
                                            formatter.string(from: snapshot.capturedAt))
    }

    // MARK: deck-shaped bits

    /// Same geometry as `ProxySectionView`'s notes: indented past the row's indicator, so a note
    /// reads as belonging to the row above it rather than as a row of its own.
    private func note(_ text: String, icon: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 9))
            Text(text).lineLimit(2)
            Spacer()
        }
        .font(.system(size: 10))
        .foregroundStyle(color)
        .padding(.leading, 34)
        .padding(.trailing, 16)
        .padding(.bottom, 2)
    }

    private func action(_ title: String, icon: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 9))
                Text(title)
                Spacer()
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 34)
        .padding(.trailing, 16)
        .padding(.bottom, 2)
    }

    private func openPage() {
        appModel.selection = .claudeTabs
        openWindow(id: "main")
        NSApp.activate()
    }

    /// "Capture now" bypasses the invariant gate so first use works — but pressed after a reboot
    /// where the restore never happened (Automation denied, or the feature was off), it would
    /// silently overwrite the only copy of the pre-reboot tabs. Ask first, exactly when there is
    /// something at stake to ask about.
    private func captureNow() {
        guard claudeTabs.isHoldingEarlierBootSnapshot else {
            claudeTabs.captureNow()
            return
        }
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = L10n.claudeTabsOverwriteConfirmTitle
        alert.informativeText = L10n.claudeTabsOverwriteConfirmMessage
        alert.addButton(withTitle: L10n.cancel)
        alert.addButton(withTitle: L10n.claudeTabsOverwriteConfirmButton)
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        claudeTabs.captureNow()
    }
}
