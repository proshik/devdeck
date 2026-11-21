import CoreGraphics

/// Drag-reordering of chain steps, kept free of SwiftUI so it can be tested on its own.
///
/// Positions between steps are "gaps": gap `0` is before the first step, gap `count` is after the
/// last one. A drop over a step lands in the gap above it in its upper half and below it in its
/// lower half, which is where the insertion line is drawn.
enum ChainStepReorder {
    /// The gap a drop over `row` lands in, given the pointer's `y` inside that row.
    static func gap(overRow row: Int, y: CGFloat, rowHeight: CGFloat) -> Int {
        y < rowHeight / 2 ? row : row + 1
    }

    /// `gap`, or nil when moving `source` there leaves the order unchanged (the gaps right above
    /// and right below the dragged step) or either index is out of range — no line, no move.
    static func effectiveGap(source: Int, gap: Int, count: Int) -> Int? {
        guard (0..<count).contains(source), (0...count).contains(gap),
              gap != source, gap != source + 1 else { return nil }
        return gap
    }

    /// `items` with the element at `source` moved into `gap`; unchanged when the move is a no-op.
    static func moving<T>(_ items: [T], from source: Int, toGap gap: Int) -> [T] {
        guard effectiveGap(source: source, gap: gap, count: items.count) != nil else { return items }
        var result = items
        let item = result.remove(at: source)
        result.insert(item, at: gap > source ? gap - 1 : gap)
        return result
    }
}
