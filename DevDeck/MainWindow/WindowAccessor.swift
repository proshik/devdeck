import SwiftUI
import AppKit

/// Reaches the `NSWindow` behind a SwiftUI scene to apply the few things SwiftUI has no API for.
///
/// Used for `titlebarSeparatorStyle`: any window with a toolbar gets `.automatic`, which draws a
/// hairline under the titlebar. On macOS 26 the toolbar metrics put that line at the height of
/// the traffic lights, so it runs straight through the close/minimise/zoom buttons and reads as a
/// rendering glitch rather than a separator.
///
/// Zero-sized on purpose — it is attached through `.background()` and only exists to hand the
/// window over.
struct WindowAccessor: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = WindowAwareView()
        view.onWindow = configure
        return view
    }

    /// Re-applied on SwiftUI updates as well: AppKit re-evaluates the separator when the toolbar
    /// changes, and re-setting an enum property is too cheap to guard against.
    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        configure(window)
    }

    /// `viewDidMoveToWindow` is the first moment `window` is non-nil — inside `makeNSView` the
    /// view is not in a hierarchy yet.
    private final class WindowAwareView: NSView {
        var onWindow: ((NSWindow) -> Void)?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            onWindow?(window)
        }
    }
}
