import XCTest
@testable import DevDeck

@MainActor
final class DiskOverviewModelTests: XCTestCase {
    private let gb: UInt64 = 1_073_741_824

    private func tree() -> FakeDirectoryReader {
        let fs = FakeDirectoryReader(root: "/h")
        fs.file("/h/work/a/Cargo.toml", bytes: 1)
        fs.file("/h/work/a/target/debug/x", bytes: 2 * gb)
        fs.file("/h/.cache/blob", bytes: gb)
        return fs
    }

    private func models(_ fs: FakeDirectoryReader, store: FakeDiskScanStore = FakeDiskScanStore(),
                        runner: FakeCommandRunner = FakeCommandRunner()) -> (DiskOverviewModel, CleanupModel, ProcessManager) {
        let manager = ProcessManager(runner: runner)
        let cleanup = CleanupModel(manager: manager, probe: FakeDockerUsageProbe([:]), facts: FakeEngineFactsProbe())
        return (DiskOverviewModel.fake(cleanup: cleanup, fs: fs, store: store), cleanup, manager)
    }

    func testAScanRunsOnlyWhenAskedAndIsSaved() async {
        let store = FakeDiskScanStore()
        let (disk, _, _) = models(tree(), store: store)
        XCTAssertNil(disk.result, "nothing is scanned on its own")

        disk.startScan()
        XCTAssertTrue(disk.isScanning)
        await disk.waitForScan()

        XCTAssertFalse(disk.isScanning)
        XCTAssertEqual(disk.result?.candidates.map(\.path), ["/h/work/a/target", "/h/.cache"])
        XCTAssertEqual(store.stored, disk.result)
        XCTAssertTrue(disk.selection.isEmpty, "nothing is ticked until the user ticks it")
    }

    func testTheLastResultComesBackAfterARelaunchButNotForAnotherRoot() async throws {
        let scanned = try DiskScanner(reader: tree(), root: "/h").scan()
        let (disk, _, _) = models(tree(), store: FakeDiskScanStore(scanned))
        XCTAssertEqual(disk.result, scanned)

        let other = try DiskScanner(reader: FakeDirectoryReader(root: "/elsewhere"), root: "/elsewhere").scan()
        let (fresh, _, _) = models(tree(), store: FakeDiskScanStore(other))
        XCTAssertNil(fresh.result)
    }

    func testStoppingAScanKeepsThePreviousResultAndSavesNothing() async throws {
        let scanned = try DiskScanner(reader: tree(), root: "/h").scan()
        let store = FakeDiskScanStore(scanned)
        let fs = SlowReader(tree())
        let slow = DiskOverviewModel(cleanup: CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()),
                                                           probe: FakeDockerUsageProbe([:]), facts: FakeEngineFactsProbe()),
                                     root: "/h", reader: fs, inspector: FakeDeletionInspector(tree()),
                                     volume: FakeVolumeUsageProbe(), store: store)
        slow.startScan()
        await yieldUntil { fs.started }
        slow.stopScan()
        fs.release()
        await slow.waitForScan()

        XCTAssertFalse(slow.isScanning)
        XCTAssertEqual(slow.result, scanned)
        XCTAssertEqual(store.saves, 0)
    }

    func testDeletingChecksAgainRunsOneCommandAndForgetsWhatIsGone() async throws {
        let fs = tree()
        let runner = FakeCommandRunner()
        let (disk, cleanup, manager) = models(fs, runner: runner)
        disk.startScan()
        await disk.waitForScan()

        disk.toggle("/h/work/a/target")
        disk.toggle("/h/.cache")
        XCTAssertEqual(disk.selectedBytes, 3 * gb)
        let review = disk.review()
        XCTAssertEqual(review.accepted.count, 2)
        XCTAssertTrue(review.rejected.isEmpty)

        disk.confirmDeletion()
        let ctrl = try XCTUnwrap(runner.controller(for: CleanupCommands.macFilesID))
        XCTAssertEqual(cleanup.lastRunID, CleanupCommands.macFilesID, "its log is the page's last action")
        ctrl.started(pid: 3)
        await yieldUntil { manager.states[CleanupCommands.macFilesID] == .running }
        XCTAssertFalse(disk.canScan, "no scan while files are being deleted")
        XCTAssertFalse(disk.canDelete)

        ctrl.terminate(0)
        await yieldUntil { manager.states[CleanupCommands.macFilesID] == .succeeded }
        // The fake tree still has target: as far as the disk says, it is not gone.
        await disk.deletionFinished(succeeded: true)
        XCTAssertEqual(disk.result?.candidates.map(\.path), ["/h/work/a/target"],
                       "an emptied cache is forgotten; a directory still on disk is kept")
        XCTAssertTrue(disk.selection.isEmpty)
        XCTAssertTrue(disk.sizesMayBeStale)
    }

    func testARejectedPathIsShownAndNotDeleted() async throws {
        let fs = tree()
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        let cleanup = CleanupModel(manager: manager, probe: FakeDockerUsageProbe([:]), facts: FakeEngineFactsProbe())
        let inspector = FakeDeletionInspector(fs)
        let disk = DiskOverviewModel(cleanup: cleanup, root: "/h", reader: fs, inspector: inspector,
                                     volume: FakeVolumeUsageProbe(), store: FakeDiskScanStore())
        disk.startScan()
        await disk.waitForScan()
        disk.toggle("/h/work/a/target")
        fs.file("/h/work/a/target/debug/.cargo-lock", bytes: 0)
        inspector.heldLocks = ["/h/work/a/target/debug/.cargo-lock"]

        let review = disk.confirmDeletion()

        XCTAssertEqual(review.rejected.map(\.reason), [.buildRunning])
        XCTAssertTrue(runner.startedCommandIDs.isEmpty, "nothing left to delete → nothing runs")
    }

    func testNothingScansWhileADockerCleanupRuns() async throws {
        let runner = FakeCommandRunner()
        let (disk, cleanup, manager) = models(tree(), runner: runner)
        cleanup.run(.buildCache, on: .colima)
        let id = CleanupCommands.id(.buildCache, on: .colima)
        try XCTUnwrap(runner.controller(for: id)).started(pid: 4)
        await yieldUntil { manager.states[id] == .running }

        disk.startScan()
        XCTAssertFalse(disk.isScanning)
    }

    func testTheMacDiskBarReadsTheVolume() async {
        let (disk, _, _) = models(tree())
        await disk.refreshMacDisk()
        XCTAssertEqual(disk.macDisk?.totalBytes, 1_000_000_000_000)
    }
}

/// Blocks the first listing until released — a scan that is still running when stopped.
private final class SlowReader: DirectoryReading, @unchecked Sendable {
    private let inner: FakeDirectoryReader
    private let gate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _started = false
    init(_ inner: FakeDirectoryReader) { self.inner = inner }
    var started: Bool { lock.lock(); defer { lock.unlock() }; return _started }
    func release() { gate.signal() }
    func entry(at path: String) -> DirectoryEntry? { inner.entry(at: path) }
    func entries(of path: String) throws -> [DirectoryEntry] {
        lock.lock(); let first = !_started; _started = true; lock.unlock()
        if first { _ = gate.wait(timeout: .now() + 5) }
        return try inner.entries(of: path)
    }
}
