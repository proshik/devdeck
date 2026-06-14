import SwiftUI

/// Live run output from `ProcessManager.logs` (ring buffer). Auto-scroll, stop, clear.
struct LogView: View {
    @Environment(ProcessManager.self) private var manager
    @Environment(CommandStore.self) private var store
    let id: UUID

    var body: some View {
        let lines = manager.logs[id]?.elements ?? []
        let isTerminal = store.commandsByID[id]?.openInTerminal ?? false

        VStack(spacing: 0) {
            if isTerminal && lines.isEmpty {
                ContentUnavailableView(
                    L10n.runningInGhostty,
                    systemImage: "terminal",
                    description: Text(L10n.ghosttyLogsNote))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(line.stream == .stderr ? Color.red : Color.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .defaultScrollAnchor(.bottom)   // keeps the scroll pinned to the bottom as the log grows
            }

            Divider()
            HStack {
                if lines.isEmpty && !isTerminal {
                    Text(L10n.logEmpty).foregroundStyle(.secondary).font(.caption)
                }
                Spacer()
                Button(L10n.stop) { manager.stop(id) }
                Button(L10n.clear) { manager.clearLog(id) }
            }
            .padding(8)
        }
    }
}
