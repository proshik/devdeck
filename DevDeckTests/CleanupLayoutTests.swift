import AppKit
import SwiftUI
import XCTest
@testable import DevDeck

/// The Cleanup page is one grouped Form whose two daemon sections have the same categories and
/// actions. When their rows shared IDs, the Form shifted rows between the sections: colima's last
/// action was drawn as its footer, outside the card, and minikube's footer as a row inside it.
/// Every button must sit inside a card — at the 600 pt cap macOS 15 gives a grouped Form and at
/// the wider macOS 26 one, in both languages, with the test-containers row present.
///
/// The cards and buttons are found by the AppKit views SwiftUI draws them with on this system;
/// where a system draws the Form differently the check is skipped and only the snapshot is kept.
@MainActor
final class CleanupLayoutTests: XCTestCase {
    func testEveryActionStaysInsideItsSectionCard() async throws {
        let row = DockerUsageRow(total: 41, active: 5, sizeBytes: 59_700_000_000, reclaimableBytes: 750_000_000)
        let now = Date()
        var usage = DockerUsage(images: row, containers: row, volumes: row, buildCache: row)
        usage.testContainers = [TestContainer(id: "a", name: "pg", image: "postgres:16",
                                              startedAt: now.addingTimeInterval(-86_400), volumes: [])]
        let manager = ProcessManager(runner: FakeCommandRunner(), vmMonitoringEnabled: { false },
                                     hostMonitoringEnabled: { false })
        var facts = EngineFacts()
        (facts.colimaInstalled, facts.colimaRunning) = (true, true)
        (facts.dockerDesktopInstalled, facts.dockerDesktopRunning) = (true, true)
        facts.minikubeInstalled = true
        facts.colimaDisks = [VMDiskFile(instance: "colima", path: "/h/.colima/_lima/_disks/colima/datadisk",
                                        allocatedBytes: 97_000_000_000)]
        let model = CleanupModel(manager: manager,
                                 probe: FakeDockerUsageProbe([.colima: usage, .dockerDesktop: usage, .minikube: usage]),
                                 facts: FakeEngineFactsProbe(facts))
        model.now = { now }
        let engine = EngineModel(candidates: [FakeEngine(.colima, running: true)])
        engine.refresh()
        // A finished scan with candidates and big folders, so the Mac-disk sections are drawn too.
        let fs = FakeDirectoryReader(root: "/h")
        fs.file("/h/work/grount/Cargo.toml", bytes: 1)
        fs.file("/h/work/grount/target/debug/x", bytes: 92_000_000_000)
        fs.file("/h/Library/Caches/c", bytes: 39_000_000_000)
        fs.file("/h/.colima/_lima/_disks/colima/datadisk", bytes: 91_000_000_000)
        let scanned = try DiskScanner(reader: fs, root: "/h").scan()
        let disk = DiskOverviewModel.fake(cleanup: model, fs: fs, store: FakeDiskScanStore(scanned))
        disk.toggle("/h/work/grount/target")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommandStore(configURL: directory.appendingPathComponent("config.json"))
        try store.save(.empty)
        let previousLanguage = LocalizationManager.shared.language
        defer { LocalizationManager.shared.language = previousLanguage }

        var checked = false
        for width: CGFloat in [600, 684] {
            let hosting = NSHostingController(rootView: CleanupView()
                .environment(model).environment(disk).environment(manager).environment(engine).environment(store)
                .frame(width: width, height: 3600))
            let window = NSWindow(contentViewController: hosting)
            window.isReleasedWhenClosed = false
            window.setFrameOrigin(NSPoint(x: -2600, y: -2600))
            window.orderFront(nil)
            defer { window.close() }
            for language in AppLanguage.allCases {
                LocalizationManager.shared.language = language
                for _ in 0..<10 {
                    try await Task.sleep(for: .milliseconds(50))
                    hosting.view.layoutSubtreeIfNeeded()
                }
                XCTAssertNotNil(model.usage[.minikube], "the fake usage must be on the page")
                XCTAssertNotNil(model.usage[.dockerDesktop])
                try saveSnapshot(hosting.view, name: "cleanup-form-\(Int(width))-\(language.rawValue)")
                let (cards, buttons) = cardsAndButtons(in: hosting.view)
                guard cards.count >= 3, !buttons.isEmpty else { continue }
                checked = true
                // Four actions per daemon section, the colima restart, the candidates and Free Selected.
                XCTAssertGreaterThanOrEqual(buttons.count, 15, "\(Int(width)) \(language)")
                for button in buttons {
                    XCTAssertTrue(cards.contains { $0.insetBy(dx: -1, dy: -1).contains(button) },
                                  "a button at \(button) is outside every card (\(Int(width)) \(language))")
                }
            }
        }
        if !checked { throw XCTSkip("this system draws the grouped Form without the expected AppKit views") }
    }

    /// The cards are the drawing views right under the Form's group container; each button has a
    /// focus-ring view. Frames are in the hosting view's coordinates.
    private func cardsAndButtons(in root: NSView) -> (cards: [CGRect], buttons: [CGRect]) {
        var cards: [CGRect] = [], buttons: [CGRect] = []
        func walk(_ view: NSView, underGroup: Bool) {
            let name = String(describing: type(of: view))
            if underGroup, name.contains("GraphicsView"), view.superview.map({ String(describing: type(of: $0)) })?
                .contains("GroupContainer") == true {
                cards.append(view.convert(view.bounds, to: root))
            }
            if name.contains("FocusRingView") { buttons.append(view.convert(view.bounds, to: root)) }
            for child in view.subviews { walk(child, underGroup: underGroup || name.contains("GroupContainer")) }
        }
        walk(root, underGroup: false)
        return (Array(Set(cards.map { [$0.minX, $0.minY, $0.width, $0.height] })).map {
            CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3])
        }, buttons)
    }

    private func saveSnapshot(_ view: NSView, name: String) throws {
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-ui-polish")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name + ".png"))
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
