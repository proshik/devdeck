import AppKit
import SwiftUI

/// Edge autoscroll for the horizontal row of tab columns while a panel item is dragged.
///
/// SwiftUI's horizontal ScrollView does not scroll during a drag session, so columns
/// beyond the visible area would be unreachable drop targets. The policy is pure; the
/// AppKit driver below only feeds it the cursor and applies the resulting offset.
/// The edge zones are not drop targets: releasing there drops on the column under the
/// cursor, or does nothing.
struct PanelEdgeAutoscroll {
    /// Zone width on each side of the visible row, measured inward from its edge.
    /// The zone also extends this far outward, so overshooting the edge keeps scrolling.
    static let edgeWidth: CGFloat = 48
    /// Speed at the inner border of the zone and at (or beyond) the visible edge.
    static let minimumSpeed: CGFloat = 200
    static let maximumSpeed: CGFloat = 900
    /// The cursor must stay in a zone this long before scrolling starts, so passing
    /// through the zone on the way to an edge column does not move the row.
    static let dwell: TimeInterval = 0.2
    /// Timer period of the driver (about one frame).
    static let interval: TimeInterval = 1.0 / 60

    /// Signed speed in points per second for a cursor at `cursorX` (0 = left visible edge):
    /// negative scrolls left, positive right, zero outside both zones.
    static func velocity(cursorX: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        guard viewportWidth > 0 else { return 0 }
        let zone = min(edgeWidth, viewportWidth / 2)
        func speed(depth: CGFloat) -> CGFloat {
            minimumSpeed + (maximumSpeed - minimumSpeed) * min(max(depth, 0), 1)
        }
        if cursorX >= -zone, cursorX < zone { return -speed(depth: (zone - cursorX) / zone) }
        if cursorX > viewportWidth - zone, cursorX <= viewportWidth + zone {
            return speed(depth: (cursorX - (viewportWidth - zone)) / zone)
        }
        return 0
    }

    /// `offset` moved by `delta` and kept inside the scrollable content.
    static func clampedOffset(_ offset: CGFloat, by delta: CGFloat,
                              contentWidth: CGFloat, viewportWidth: CGFloat) -> CGFloat {
        min(max(offset + delta, 0), max(contentWidth - viewportWidth, 0))
    }

    private var zoneEntered: (direction: CGFloat, at: TimeInterval)?

    /// The next offset for one timer tick, or nil when the row should stay where it is:
    /// cursor outside the row or its zones, still dwelling, or already at the content edge.
    mutating func step(cursorX: CGFloat, cursorInRow: Bool, viewportWidth: CGFloat,
                       contentWidth: CGFloat, offset: CGFloat,
                       now: TimeInterval, elapsed: TimeInterval) -> CGFloat? {
        let speed = cursorInRow ? Self.velocity(cursorX: cursorX, viewportWidth: viewportWidth) : 0
        guard speed != 0 else { zoneEntered = nil; return nil }
        let direction: CGFloat = speed < 0 ? -1 : 1
        if zoneEntered?.direction != direction { zoneEntered = (direction, now) }
        guard let entered = zoneEntered, now - entered.at >= Self.dwell else { return nil }
        let next = Self.clampedOffset(offset, by: speed * CGFloat(elapsed),
                                      contentWidth: contentWidth, viewportWidth: viewportWidth)
        return next == offset ? nil : next
    }
}

/// Runs the edge autoscroll for one horizontal NSScrollView while the mouse button is down.
/// Drop-target callbacks start it; it stops by itself once the drag ends.
@MainActor final class PanelRowAutoscroller {
    weak var scrollView: NSScrollView?
    private var timer: Timer?
    private var policy = PanelEdgeAutoscroll()
    private var lastTick: TimeInterval = 0
    private var onRelease: [() -> Void] = []

    var isTracking: Bool { timer != nil }

    /// `onRelease` runs once the mouse button is up, whether or not anything was dropped.
    func beginTracking(onRelease: (() -> Void)? = nil) {
        if let onRelease { self.onRelease.append(onRelease) }
        guard timer == nil, scrollView != nil else { return }
        policy = PanelEdgeAutoscroll()
        lastTick = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: PanelEdgeAutoscroll.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // A drag session runs the main loop in event-tracking mode.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func endTracking() {
        timer?.invalidate()
        timer = nil
        let callbacks = onRelease
        onRelease = []
        callbacks.forEach { $0() }
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0,
              let scrollView, let window = scrollView.window,
              let document = scrollView.documentView else { return endTracking() }
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastTick = now }
        let clip = scrollView.contentView
        let cursor = scrollView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        let inRow = cursor.y >= scrollView.bounds.minY && cursor.y <= scrollView.bounds.maxY
        guard let offset = policy.step(cursorX: cursor.x - scrollView.bounds.minX, cursorInRow: inRow,
                                       viewportWidth: clip.bounds.width,
                                       contentWidth: document.frame.width, offset: clip.bounds.origin.x,
                                       now: now, elapsed: now - lastTick) else { return }
        clip.scroll(to: NSPoint(x: offset, y: clip.bounds.origin.y))
        scrollView.reflectScrolledClipView(clip)
    }
}

/// Hands the enclosing horizontal NSScrollView of the row to the autoscroller.
struct PanelRowScrollViewLocator: NSViewRepresentable {
    let autoscroller: PanelRowAutoscroller

    func makeNSView(context: Context) -> LocatorView {
        let view = LocatorView()
        view.autoscroller = autoscroller
        return view
    }

    func updateNSView(_ view: LocatorView, context: Context) {
        view.autoscroller = autoscroller
        view.attach()
    }

    final class LocatorView: NSView {
        weak var autoscroller: PanelRowAutoscroller?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }
        func attach() {
            guard let scrollView = enclosingScrollView else { return }
            autoscroller?.scrollView = scrollView
        }
    }
}
