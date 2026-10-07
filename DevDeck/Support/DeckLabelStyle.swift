import SwiftUI

/// Shared leading column for utility rows in the menu bar panel.
struct DeckLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 20)
            configuration.title
        }
    }
}
