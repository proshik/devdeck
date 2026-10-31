import AppKit
import Observation

/// Status-bar popovers can inherit the menu bar's appearance instead of NSApp's.
/// Bind the native popover explicitly; nil restores inheritance for System.
@MainActor final class PopoverAppearanceBinding {
    private weak var popover: NSPopover?
    private let manager: AppearanceManager
    init(_ popover: NSPopover, manager: AppearanceManager = .shared) {
        self.popover = popover; self.manager = manager; observe()
    }
    private func observe() {
        guard let popover else { return }
        let appearance = withObservationTracking { manager.appearance } onChange: { [weak self] in
            Task { @MainActor in self?.observe() }
        }
        popover.appearance = appearance.nsAppearance
    }
}
