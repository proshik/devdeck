import XCTest
@testable import DevDeck

/// What the Cleanup page learns about the engines without spawning anything.
final class EngineFactsTests: XCTestCase {
    private let home = "/Users/u"

    func testOnlyTheDefaultColimaProfileCountsForTheSection() {
        let paths = FakePathProbe()
        paths.directories["\(home)/.colima/_lima"] = ["colima", "colima-krill", "_disks"]
        paths.files["\(home)/.colima/_lima/colima-krill/ha.pid"] = "42"
        let liveness = FakeLiveness()
        liveness.alive = [42]
        let colima = ColimaEngine(home: home, paths: paths, liveness: liveness)

        XCTAssertTrue(colima.isRunning(), "the tray still sees a colima running")
        XCTAssertFalse(colima.isDefaultProfileRunning(), "but colima ssh would reach the stopped default one")

        paths.files["\(home)/.colima/_lima/colima/ha.pid"] = "7\n"
        liveness.alive = [7]
        XCTAssertTrue(colima.isDefaultProfileRunning())
    }

    func testEveryColimaProfileDiskIsListedWithItsAllocatedSize() {
        let paths = FakePathProbe()
        paths.existing = ["/opt/homebrew/bin/colima"]
        let disks = "\(home)/.colima/_lima/_disks"
        paths.directories[disks] = ["colima-krill", "colima"]
        paths.existing.formUnion(["\(disks)/colima/datadisk", "\(disks)/colima-krill/datadisk"])
        let fs = FakeDirectoryReader(root: home)
        fs.file("\(disks)/colima/datadisk", bytes: 91_000_000_000)

        let facts = LiveEngineFactsProbe(home: home, paths: paths, reader: fs,
                                         colima: ColimaEngine(home: home, paths: paths, liveness: FakeLiveness()),
                                         dockerDesktop: FakeEngine(.dockerDesktop, installed: false)).sample()

        XCTAssertTrue(facts.colimaInstalled)
        XCTAssertFalse(facts.colimaRunning)
        XCTAssertEqual(facts.colimaDisks.map(\.instance), ["colima", "colima-krill"])
        XCTAssertEqual(facts.colimaDisks.first?.allocatedBytes, 91_000_000_000)
        XCTAssertNil(facts.colimaDisks.last?.allocatedBytes, "a disk that cannot be read has no size, not 0")
        XCTAssertFalse(facts.dockerDesktopInstalled)
    }

    func testDockerDesktopRunningNeedsItInstalled() {
        let paths = FakePathProbe()
        let facts = LiveEngineFactsProbe(home: home, paths: paths, reader: FakeDirectoryReader(root: home),
                                         colima: ColimaEngine(home: home, paths: paths, liveness: FakeLiveness()),
                                         dockerDesktop: FakeEngine(.dockerDesktop, installed: true, running: true)).sample()
        XCTAssertTrue(facts.dockerDesktopInstalled)
        XCTAssertTrue(facts.dockerDesktopRunning)
        XCTAssertTrue(facts.shouldProbe(.dockerDesktop))
        XCTAssertFalse(facts.isInstalled(.colima))
    }

    func testMinikubeIsFoundByItsBinaryOrHomeAndReportsItsDriver() {
        let paths = FakePathProbe()
        let minikube = MinikubePresence(home: home, paths: paths)
        XCTAssertFalse(minikube.isInstalled())
        paths.existing = ["\(home)/.minikube"]
        XCTAssertTrue(minikube.isInstalled())
        XCTAssertNil(minikube.driver())
        paths.files["\(home)/.minikube/profiles/minikube/config.json"] = #"{"Name":"minikube","Driver":"docker"}"#
        XCTAssertEqual(minikube.driver(), "docker")
        paths.files["\(home)/.minikube/profiles/minikube/config.json"] = "not json"
        XCTAssertNil(minikube.driver())
    }

    func testMinikubeIsProbedWheneverInstalledAndEnginesOnlyWhenRunning() {
        var facts = EngineFacts()
        facts.colimaInstalled = true
        facts.minikubeInstalled = true
        XCTAssertFalse(facts.shouldProbe(.colima))
        XCTAssertTrue(facts.shouldProbe(.minikube))
        XCTAssertFalse(facts.shouldProbe(.dockerDesktop))
    }
}
