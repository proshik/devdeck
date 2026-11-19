import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Live preview of dragging a tab heading within the row of tab columns.
///
/// The dragged column becomes a placeholder that travels to the insertion point while
/// the other columns make room, so the resulting order is visible before the drop.
/// The preview lives in view state only; the configuration changes on drop alone.
struct PanelTabReorder: Equatable {
    let original: [String]
    let dragged: String
    /// Index of the placeholder among the columns that are not being dragged.
    private(set) var insertion: Int

    init?(order: [String], dragged: String) {
        guard let index = order.firstIndex(of: dragged) else { return nil }
        original = order
        self.dragged = dragged
        insertion = index
    }

    var others: [String] { original.filter { $0 != dragged } }

    var previewOrder: [String] {
        var order = others
        order.insert(dragged, at: min(insertion, order.count))
        return order
    }

    /// The placeholder sits where the tab started: dropping changes nothing.
    var isNoOp: Bool { previewOrder == original }

    /// Columns whose middle lies left of the cursor come before the insertion point:
    /// left of a column's middle inserts before it, right of it inserts after it.
    static func insertionIndex(cursorX: CGFloat, otherMidXs: [CGFloat]) -> Int {
        otherMidXs.filter { $0 < cursorX }.count
    }

    /// Middle of the `slot`-th column in a row of equal columns.
    static func slotMidX(_ slot: Int, columnWidth: CGFloat, spacing: CGFloat) -> CGFloat {
        CGFloat(slot) * (columnWidth + spacing) + columnWidth / 2
    }

    /// Middles of the other columns as currently shown, i.e. with the placeholder at `insertion`.
    func displayedOtherMidXs(columnWidth: CGFloat, spacing: CGFloat) -> [CGFloat] {
        others.indices.map { index in
            Self.slotMidX(index < insertion ? index : index + 1, columnWidth: columnWidth, spacing: spacing)
        }
    }

    /// Moves the placeholder for a cursor at `cursorX` in row coordinates; true if it moved.
    mutating func update(cursorX: CGFloat, columnWidth: CGFloat, spacing: CGFloat) -> Bool {
        let next = Self.insertionIndex(cursorX: cursorX,
                                       otherMidXs: displayedOtherMidXs(columnWidth: columnWidth, spacing: spacing))
        guard next != insertion else { return false }
        insertion = next
        return true
    }

    /// Back to the starting position, e.g. when the cursor leaves the row.
    mutating func revert() {
        insertion = original.firstIndex(of: dragged) ?? insertion
    }

    /// Applies the previewed order. A no-op preview leaves the configuration untouched.
    func apply(to panel: inout PanelConfiguration) {
        guard !isNoOp, let section = PanelSection(rawValue: dragged) else { return }
        let others = self.others
        if insertion < others.count, let target = PanelSection(rawValue: others[insertion]) {
            panel.moveSection(section, before: target)
        } else if let last = others.last, let target = PanelSection(rawValue: last) {
            panel.moveSection(section, after: target)
        }
    }
}

/// Receives a dragged tab heading anywhere over the row while a heading drag is active.
/// It sits above the columns, so their module drop targets do not swallow the drag.
struct PanelTabRowDropDelegate: DropDelegate {
    @Binding var reorder: PanelTabReorder?
    let columnWidth: CGFloat
    let spacing: CGFloat
    let onEnter: () -> Void
    let commit: (PanelTabReorder) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        reorder != nil && info.hasItemsConforming(to: [.devDeckPanelItem])
    }

    func dropEntered(info: DropInfo) {
        onEnter()
        move(to: info.location.x)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        move(to: info.location.x)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        guard var next = reorder else { return }
        next.revert()
        withAnimation { reorder = next }
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let reorder else { return false }
        commit(reorder)
        return true
    }

    private func move(to cursorX: CGFloat) {
        guard var next = reorder, next.update(cursorX: cursorX, columnWidth: columnWidth, spacing: spacing) else { return }
        withAnimation { reorder = next }
    }
}

extension PanelDragItem {
    /// Item provider for `.onDrag`, which unlike `.draggable` reports when the drag starts.
    func itemProvider() -> NSItemProvider {
        let provider = NSItemProvider()
        let data = try? JSONEncoder().encode(self)
        provider.registerDataRepresentation(forTypeIdentifier: UTType.devDeckPanelItem.identifier,
                                            visibility: .ownProcess) { completion in
            completion(data, nil)
            return nil
        }
        return provider
    }
}
