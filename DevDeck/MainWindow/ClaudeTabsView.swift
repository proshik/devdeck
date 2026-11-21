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

/// Three groups on the window's grouped form: the restore switch and its page-wide actions, the
/// tabs open right now, and the session history — everything the catalogue remembers within the
/// window, minus whatever is already in the second group. Every row in either list can be opened
/// on its own; there is no "restore everything" button there, only the full restore in the first
/// group.
///
/// A row without a session still restores — as a shell in its directory — and saying so plainly
/// is what keeps that from reading as a bug.
struct ClaudeTabsView: View {
    @Environment(CommandStore.self) private var store
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
        Form {
            restoreSection
            openTabsSection
            historySection
        }
        .formStyle(.grouped)
        .navigationTitle(L10n.claudeTabsSection)
        .task { await claudeTabs.rebuildHistory() }
    }

    private var restoreSection: some View {
        Section {
            Toggle(L10n.claudeTabsRestoreToggle, isOn: Binding(
                get: { store.config.settings.claudeTabsRestore },
                set: { store.setClaudeTabsRestore($0) }
            ))
            if let capturedAt = claudeTabs.snapshot?.capturedAt, !entries.isEmpty {
                LabeledContent(L10n.claudeTabsSnapshotTaken) {
                    Text(AppDateFormat.string(capturedAt, date: .abbreviated, time: .shortened))
                        .monospacedDigit()
                }
            }
            if let error = claudeTabs.lastError {
                Text(error)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            FormActionRow {
                Button(L10n.claudeTabsCaptureNow) { captureNow() }
                Button(L10n.claudeTabsRestoreNow) { claudeTabs.restoreNow() }
                    .disabled(entries.isEmpty)
            }
        } header: {
            Text(L10n.claudeTabsRestoreSection)
        } footer: {
            FormFooter(L10n.claudeTabsIntro)
        }
    }

    private var openTabsSection: some View {
        Section(L10n.claudeTabsOpenSection) {
            if entries.isEmpty {
                Text(L10n.claudeTabsNoSnapshot).foregroundStyle(.secondary)
            } else {
                ForEach(entries) { entry in
                    HStack(spacing: 12) {
                        SessionRowText(title: entry.title, directory: entry.workingDirectory,
                                       details: [L10n.claudeTabsAgentName(entry.provider)])
                        Spacer(minLength: 8)
                        Text(entry.sessionID == nil ? L10n.claudeTabsDirectoryOnly : L10n.claudeTabsSessionFound)
                            .foregroundStyle(entry.sessionID == nil ? .secondary : .primary)
                            .fixedSize()
                        openTabButton(entry)
                    }
                }
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
        }
    }

    private var historySection: some View {
        Section {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField(L10n.claudeTabsHistorySearchPlaceholder, text: $historyQuery,
                          prompt: Text(L10n.claudeTabsHistorySearchPlaceholder))
                    .textFieldStyle(.plain)
                    .labelsHidden()
            }
            if filteredHistory.isEmpty {
                Text(emptyHistoryMessage).foregroundStyle(.secondary)
            } else {
                ForEach(filteredHistory) { entry in
                    HStack(spacing: 12) {
                        SessionRowText(title: entry.title, directory: entry.directory,
                                       details: [L10n.claudeTabsAgentName(entry.provider),
                                                 AppDateFormat.string(entry.lastActivity, date: .abbreviated,
                                                                      time: .shortened)])
                        Spacer(minLength: 8)
                        Button(L10n.claudeTabsOpen) {
                            claudeTabs.open(AgentSession(id: entry.sessionID, title: entry.title,
                                                         lastActivity: entry.lastActivity,
                                                         directory: entry.directory),
                                            providerID: entry.provider)
                        }
                    }
                }
            }
        } header: {
            HStack {
                Text(L10n.claudeTabsHistorySection)
                Spacer()
                if claudeTabs.isBuildingHistory { ProgressView().controlSize(.small) }
                Button(L10n.claudeTabsHistoryRefresh) { Task { await claudeTabs.rebuildHistory() } }
                    .disabled(claudeTabs.isBuildingHistory)
            }
        } footer: {
            FormFooter(L10n.claudeTabsHistoryIntro)
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

/// A tab or session row: the title, and under it "directory · details" in a caption. A long
/// directory is cut in the middle so both its root and its last component stay readable, and the
/// details after it stay whole; the full strings are in the tooltip.
private struct SessionRowText: View {
    let title: String
    let directory: String
    let details: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(1).truncationMode(.tail).help(title)
            HStack(spacing: 0) {
                Text(directory).lineLimit(1).truncationMode(.middle)
                Text(details.map { " · " + $0 }.joined()).lineLimit(1).fixedSize()
            }
            .font(.caption).foregroundStyle(.secondary)
            .help(([directory] + details).joined(separator: " · "))
        }
    }
}
