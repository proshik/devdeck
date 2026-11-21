import SwiftUI

// Shared rows that keep every page of the main window on one grouped-Form system, as System
// Settings does (macOS HIG: Settings, Layout): explanations sit under their group as a caption
// footer, actions sit at the trailing edge of a row rather than as a lone leading button or in a
// group of their own, and a row that opens another page of the window carries a chevron.

/// Explanatory text under a group: caption size, secondary color, wraps to the group's width.
struct FormFooter: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text).font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A row whose buttons sit at the trailing edge, with an optional status on the leading side.
struct FormActionRow<Leading: View, Actions: View>: View {
    private let leading: Leading
    private let actions: Actions

    init(@ViewBuilder actions: () -> Actions) where Leading == EmptyView {
        leading = EmptyView()
        self.actions = actions()
    }

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder actions: () -> Actions) {
        self.leading = leading()
        self.actions = actions()
    }

    var body: some View {
        HStack(spacing: 8) {
            leading
            Spacer(minLength: 8)
            actions
        }
    }
}

/// A row that opens another page of this window, with an optional leading icon and a secondary
/// value before the chevron.
struct FormNavigationRow: View {
    let title: String
    var icon: String?
    var value: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack {
                if let icon { Label(title, systemImage: icon) } else { Text(title) }
                Spacer()
                if let value { Text(value).monospacedDigit().foregroundStyle(.secondary) }
                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain).controlHoverFeedback()
    }
}
