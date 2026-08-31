import SwiftUI

/// Whether the per-row "Open" action belongs on a snapshot row: never on one whose session is
/// already open, since pressing it there would only add a SECOND tab for the same session — never
/// what the user wants (FIX 2). A row with no resolved session (`sessionID == nil`) has never had
/// an action here either way — there is nothing to duplicate, and nothing to reopen.
///
/// A pure function of exactly the two things that decide it, kept out of the view so the rule is
/// testable on its own — see `ClaudeTabsViewTests`.
enum SnapshotRowAction {
    static func isVisible(sessionID: String?, openSessionIDs: Set<String>) -> Bool {
        guard let sessionID else { return false }
        return !openSessionIDs.contains(sessionID)
    }
}

/// Two lists: the tabs open right now (as before), and — new — the session history: everything
/// the catalogue remembers within the window, minus whatever is already in the first list. Every
/// row in either list can be opened on its own; there is no "restore everything" button here, only
/// the full restore that already lives in the header.
///
/// A row without a session still restores — as a shell in its directory — and saying so plainly
/// is what keeps that from reading as a bug.
///
/// Laid out like `CleanupView`: a title with its actions on the same line, one caption explaining
/// what the page is for, then the content. The first version stacked the buttons under the title
/// and skipped the explanation, which is why it sat oddly next to the app's other pages. The
/// history section repeats that same shape for itself, rather than borrowing `CleanupView`'s
/// `GroupBox` styling — the two sections belong to the same page and read better sharing one
/// vocabulary than mixing two.
struct ClaudeTabsView: View {
    @Environment(ClaudeTabsModel.self) private var claudeTabs
    @State private var historyQuery = ""

    private var entries: [ClaudeTabEntry] { claudeTabs.snapshot?.tabs ?? [] }

    /// The pure decisions — exclusion, then search — live in `SessionCatalog`, not here: this is
    /// just wiring the model's `liveOpenSessionIDs` (FIX 1 — the truthful "open right now" set,
    /// NOT the snapshot) and the search field's text through them.
    private var filteredHistory: [CatalogEntry] {
        SessionCatalog.matching(
            SessionCatalog.historyEntries(from: claudeTabs.historyEntries,
                                          excludingOpenSessionIDs: claudeTabs.liveOpenSessionIDs),
            query: historyQuery)
    }

    var body: some View {
        // No ScrollView around either `Table`: `Table` scrolls itself, and nesting the two breaks
        // its sizing. The open-tabs table gets a capped height instead, so the history table below
        // it — usually the longer of the two — gets the rest of the page.
        VStack(alignment: .leading, spacing: 12) {
            header

            if entries.isEmpty {
                Text(L10n.claudeTabsNoSnapshot).foregroundStyle(.secondary)
            } else {
                Table(entries) {
                    TableColumn("#") { Text("\($0.order + 1)") }.width(24)
                    TableColumn(L10n.claudeTabsColumnTitle) { Text($0.title) }
                    TableColumn(L10n.claudeTabsColumnDirectory) {
                        Text($0.workingDirectory).foregroundStyle(.secondary)
                    }
                    TableColumn(L10n.claudeTabsColumnAgent) { entry in
                        Text(L10n.claudeTabsAgentName(entry.provider)).foregroundStyle(.secondary)
                    }
                    TableColumn(L10n.claudeTabsColumnSession) { entry in
                        Text(entry.sessionID == nil
                             ? L10n.claudeTabsDirectoryOnly
                             : L10n.claudeTabsSessionFound)
                            .foregroundStyle(entry.sessionID == nil ? .secondary : .primary)
                    }
                    TableColumn("") { entry in openTabButton(entry) }.width(70)
                }
                .frame(maxHeight: 220)
            }

            Divider()

            historySection
        }
        .padding()
        .task { await claudeTabs.rebuildHistory() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.claudeTabsSection).font(.title2).bold()
                Spacer()
                Button(L10n.claudeTabsCaptureNow) { captureNow() }
                Button(L10n.claudeTabsRestoreNow) { claudeTabs.restoreNow() }
                    .disabled(entries.isEmpty)
            }
            Text(L10n.claudeTabsIntro).font(.caption).foregroundStyle(.secondary)
            if let capturedAt = claudeTabs.snapshot?.capturedAt, !entries.isEmpty {
                Text(L10n.claudeTabsCapturedAt(capturedAt.formatted(date: .abbreviated,
                                                                    time: .shortened)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            if let error = claudeTabs.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Nothing to show for a directory-only row: `AgentSession.id` is not optional, so there is no
    /// session to open again — the live tab already IS the "open" state for that row. Nothing to
    /// show either for a row whose session is already open right now (FIX 2, via
    /// `SnapshotRowAction`): pressing the action there would only open a SECOND tab for the same
    /// session.
    ///
    /// Calls the directory/session-id/provider overload of `open`, not the `AgentSession` one: a
    /// `ClaudeTabEntry` has no activity timestamp of its own, and `RestoreAction.newTab` never
    /// reads one either, so there is nothing here to fabricate one for.
    @ViewBuilder
    private func openTabButton(_ entry: ClaudeTabEntry) -> some View {
        if let sessionID = entry.sessionID,
           SnapshotRowAction.isVisible(sessionID: sessionID, openSessionIDs: claudeTabs.liveOpenSessionIDs) {
            Button(L10n.claudeTabsOpen) {
                claudeTabs.open(directory: entry.workingDirectory, sessionID: sessionID,
                                providerID: entry.provider)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.claudeTabsHistorySection).font(.title3).bold()
                Spacer()
                if claudeTabs.isBuildingHistory { ProgressView().controlSize(.small) }
                Button(L10n.claudeTabsHistoryRefresh) { Task { await claudeTabs.rebuildHistory() } }
                    .disabled(claudeTabs.isBuildingHistory)
            }
            Text(L10n.claudeTabsHistoryIntro).font(.caption).foregroundStyle(.secondary)
            TextField(L10n.claudeTabsHistorySearchPlaceholder, text: $historyQuery)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 320)

            if filteredHistory.isEmpty {
                Text(emptyHistoryMessage).font(.caption).foregroundStyle(.secondary)
            } else {
                Table(filteredHistory) {
                    TableColumn(L10n.claudeTabsColumnTitle) { Text($0.title) }
                    TableColumn(L10n.claudeTabsColumnDirectory) {
                        Text($0.directory).foregroundStyle(.secondary)
                    }
                    TableColumn(L10n.claudeTabsColumnAgent) { entry in
                        Text(L10n.claudeTabsAgentName(entry.provider)).foregroundStyle(.secondary)
                    }
                    TableColumn(L10n.claudeTabsColumnLastActive) { entry in
                        Text(entry.lastActivity.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    TableColumn("") { entry in
                        Button(L10n.claudeTabsOpen) {
                            claudeTabs.open(AgentSession(id: entry.sessionID, title: entry.title,
                                                         lastActivity: entry.lastActivity,
                                                         directory: entry.directory),
                                            providerID: entry.provider)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }.width(70)
                }
            }
        }
    }

    /// Three distinct reasons the list could be empty, and each gets its own line so it never
    /// reads as the same "nothing here" whether or not something is actually wrong.
    private var emptyHistoryMessage: String {
        if claudeTabs.historyEntries.isEmpty {
            return claudeTabs.isBuildingHistory ? L10n.claudeTabsHistoryBuilding : L10n.claudeTabsHistoryEmpty
        }
        return L10n.claudeTabsHistoryNoMatches
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
