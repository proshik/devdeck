import AppKit
import SwiftUI

/// Reports the height a SwiftUI `Table` needs to show all its rows — header and insets included —
/// so a short table can be framed to its content instead of padding itself out with empty striped
/// rows. SwiftUI's `Table` has no fitting size of its own, and row height is not a constant (a row
/// with a bordered button is taller than one with text only), so the height is read from the
/// AppKit table underneath: put this in the background of any cell.
struct TableContentHeightReader: NSViewRepresentable {
    let onChange: (CGFloat) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onChange = onChange
        DispatchQueue.main.async { view.measure() }
    }

    final class ReaderView: NSView {
        var onChange: ((CGFloat) -> Void)?
        private weak var observedTable: NSTableView?
        private var lastReported: CGFloat?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in self?.measure() }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        func measure() {
            guard let scrollView = enclosingScrollView,
                  let table = scrollView.documentView as? NSTableView else { return }
            if observedTable !== table {
                NotificationCenter.default.removeObserver(self)
                observedTable = table
                table.postsFrameChangedNotifications = true
                NotificationCenter.default.addObserver(self, selector: #selector(tableFrameChanged),
                                                       name: NSView.frameDidChangeNotification, object: table)
            }
            guard let height = Self.contentHeight(of: table, in: scrollView), height != lastReported else { return }
            lastReported = height
            onChange?(height)
        }

        @objc private func tableFrameChanged() { measure() }

        /// Header (it lives in the scroll view's top inset), every row, and the same padding under
        /// the last row as the table style keeps above the first one.
        static func contentHeight(of table: NSTableView, in scrollView: NSScrollView) -> CGFloat? {
            guard table.numberOfRows > 0 else { return nil }
            let first = table.rect(ofRow: 0)
            let last = table.rect(ofRow: table.numberOfRows - 1)
            let insets = scrollView.contentView.contentInsets
            return ceil(insets.top + last.maxY + first.minY + insets.bottom)
        }
    }
}
