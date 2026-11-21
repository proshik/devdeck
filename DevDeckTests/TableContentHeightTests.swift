import AppKit
import SwiftUI
import XCTest
@testable import DevDeck

/// A short table framed by `TableContentHeightReader` shows every row and no empty striped rows
/// under them; a long one stops at its cap and scrolls. Rows mix text-only cells with a bordered
/// button, the way the "Agent tabs" table does, since the two differ in height.
@MainActor
final class TableContentHeightTests: XCTestCase {
    private struct Row: Identifiable { let id: Int; let hasButton: Bool }

    private struct Host: View {
        let rows: [Row]
        @State private var height: CGFloat?

        var body: some View {
            VStack(spacing: 0) {
                Table(rows) {
                    TableColumn("#") { row in
                        Text("\(row.id)").background {
                            if row.id == rows.first?.id { TableContentHeightReader { height = $0 } }
                        }
                    }
                    TableColumn("Title") { row in Text("Tab \(row.id)") }
                    TableColumn("") { row in
                        if row.hasButton { Button("Open") {}.buttonStyle(.bordered).controlSize(.small) }
                    }.width(70)
                }
                .frame(height: min(220, height ?? 220))
                Spacer(minLength: 0)
            }
        }
    }

    func testShortTableIsAsTallAsItsRows() async throws {
        for rows in [[Row(id: 1, hasButton: false)],
                     [Row(id: 1, hasButton: true), Row(id: 2, hasButton: false), Row(id: 3, hasButton: true)]] {
            let (window, scroll, table) = try await host(rows)
            defer { window.close() }
            let content = scroll.contentView.contentInsets.top + table.rect(ofRow: table.numberOfRows - 1).maxY
            XCTAssertLessThan(scroll.frame.height, 220, "\(rows.count) rows must not take the capped height")
            XCTAssertGreaterThanOrEqual(scroll.frame.height + 0.5, content, "every row must be visible")
            XCTAssertLessThan(scroll.frame.height - content, table.rect(ofRow: 0).height,
                              "no room left for an empty row under the last one")
        }
    }

    func testLongTableStopsAtTheCapAndScrolls() async throws {
        let rows = (1...20).map { Row(id: $0, hasButton: $0.isMultiple(of: 2)) }
        let (window, scroll, table) = try await host(rows)
        defer { window.close() }
        XCTAssertEqual(scroll.frame.height, 220, accuracy: 0.5)
        XCTAssertGreaterThan(table.rect(ofRow: table.numberOfRows - 1).maxY, scroll.frame.height)
    }

    private func host(_ rows: [Row]) async throws -> (NSWindow, NSScrollView, NSTableView) {
        let hosting = NSHostingController(rootView: Host(rows: rows).frame(width: 600, height: 500))
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -2600, y: -2600))
        window.orderFront(nil)
        for _ in 0..<20 {
            try await Task.sleep(for: .milliseconds(50))
            hosting.view.layoutSubtreeIfNeeded()
        }
        let table = try XCTUnwrap(findTable(in: hosting.view))
        let scroll = try XCTUnwrap(table.enclosingScrollView)
        return (window, scroll, table)
    }

    private func findTable(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        for child in view.subviews { if let match = findTable(in: child) { return match } }
        return nil
    }
}
