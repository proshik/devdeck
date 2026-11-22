import Foundation
@testable import DevDeck

/// Fixed engine facts — no real `~/.colima`, app bundle or socket is looked at.
final class FakeEngineFactsProbe: EngineFactsProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var _facts: EngineFacts
    init(_ facts: EngineFacts = EngineFacts()) { _facts = facts }
    var facts: EngineFacts {
        get { lock.lock(); defer { lock.unlock() }; return _facts }
        set { lock.lock(); _facts = newValue; lock.unlock() }
    }
    func sample() -> EngineFacts { facts }

    /// colima installed and running, minikube installed — the developer's machine.
    static var colimaAndMinikube: FakeEngineFactsProbe {
        var facts = EngineFacts()
        facts.colimaInstalled = true
        facts.colimaRunning = true
        facts.minikubeInstalled = true
        return FakeEngineFactsProbe(facts)
    }
}

final class FakeVolumeUsageProbe: VolumeUsageProbing, @unchecked Sendable {
    var info: VMDiskInfo?
    init(_ info: VMDiskInfo? = VMDiskInfo(usedBytes: 700_000_000_000, totalBytes: 1_000_000_000_000)) { self.info = info }
    func sample(_ path: String) -> VMDiskInfo? { info }
}

final class FakeDiskScanStore: DiskScanStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var _stored: DiskScanResult?
    private var _saves = 0
    init(_ stored: DiskScanResult? = nil) { _stored = stored }
    var stored: DiskScanResult? { lock.lock(); defer { lock.unlock() }; return _stored }
    var saves: Int { lock.lock(); defer { lock.unlock() }; return _saves }
    func load() -> DiskScanResult? { stored }
    func save(_ result: DiskScanResult) { lock.lock(); _stored = result; _saves += 1; lock.unlock() }
}

extension DiskOverviewModel {
    /// A model over an in-memory tree rooted at `/h`.
    @MainActor
    static func fake(cleanup: CleanupModel, fs: FakeDirectoryReader = FakeDirectoryReader(root: "/h"),
                     store: FakeDiskScanStore = FakeDiskScanStore()) -> DiskOverviewModel {
        DiskOverviewModel(cleanup: cleanup, root: "/h", reader: fs, inspector: FakeDeletionInspector(fs),
                          volume: FakeVolumeUsageProbe(), store: store)
    }
}
