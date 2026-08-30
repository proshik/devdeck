import SwiftUI

/// The full snapshot: which tabs would come back, and which of them we could tie to a session.
///
/// A row without a session still restores — as a shell in its directory — and saying so plainly
/// is what keeps that from reading as a bug.
///
/// Laid out like `CleanupView`: a title with its actions on the same line, one caption explaining
/// what the page is for, then the content. The first version stacked the buttons under the title
/// and skipped the explanation, which is why it sat oddly next to the app's other pages.
struct ClaudeTabsView: View {
    @Environment(ClaudeTabsModel.self) private var claudeTabs

    private var entries: [ClaudeTabEntry] { claudeTabs.snapshot?.tabs ?? [] }

    var body: some View {
        // No ScrollView around this: `Table` scrolls itself, and nesting the two breaks its sizing.
        VStack(alignment: .leading, spacing: 12) {
            header

            if entries.isEmpty {
                Text(L10n.claudeTabsNoSnapshot).foregroundStyle(.secondary)
                Spacer()
            } else {
                Table(entries) {
                    TableColumn("#") { Text("\($0.order + 1)") }.width(24)
                    TableColumn(L10n.claudeTabsColumnTitle) { Text($0.title) }
                    TableColumn(L10n.claudeTabsColumnDirectory) {
                        Text($0.workingDirectory).foregroundStyle(.secondary)
                    }
                    TableColumn(L10n.claudeTabsColumnSession) { entry in
                        Text(entry.sessionID == nil
                             ? L10n.claudeTabsDirectoryOnly
                             : L10n.claudeTabsSessionFound)
                            .foregroundStyle(entry.sessionID == nil ? .secondary : .primary)
                    }
                }
            }
        }
        .padding()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L10n.claudeTabsSection).font(.title2).bold()
                Spacer()
                Button(L10n.claudeTabsCaptureNow) { claudeTabs.captureNow() }
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
}
