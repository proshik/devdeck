import SwiftUI

/// Borderless controls keep their native action, focus and accessibility behavior.
/// Only the hover background is added, without changing their size or hit area.
private struct ControlHoverFeedback: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .background(Color.primary.opacity(isEnabled && isHovered ? 0.10 : 0),
                        in: RoundedRectangle(cornerRadius: 5))
            .onHover { isHovered = $0 }
    }
}

extension View {
    func controlHoverFeedback() -> some View {
        modifier(ControlHoverFeedback())
    }
}
