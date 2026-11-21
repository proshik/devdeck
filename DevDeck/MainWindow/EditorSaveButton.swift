import SwiftUI

/// The editors' toolbar "Save": the prominent (accent) style only while there is something to
/// save; otherwise a plain, disabled toolbar button. ⌘S and the tooltip stay in both states.
struct EditorSaveButton: View {
    let hasChanges: Bool
    let action: () -> Void

    var body: some View {
        styled(Button(L10n.save, action: action))
            .disabled(!hasChanges)
            .keyboardShortcut("s")
            .help(L10n.saveHelp)
    }

    @ViewBuilder private func styled(_ button: Button<Text>) -> some View {
        if hasChanges { button.buttonStyle(.borderedProminent) } else { button }
    }
}
