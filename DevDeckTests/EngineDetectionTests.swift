import XCTest
@testable import DevDeck

final class EngineDetectionTests: XCTestCase {
    private let home = "/Users/test"

    // MARK: colima

    private func colima(_ configure: (FakePathProbe, FakeLiveness) -> Void) -> ColimaEngine {
        let paths = FakePathProbe()
        let liveness = FakeLiveness()
        configure(paths, liveness)
        return ColimaEngine(home: home, paths: paths, liveness: liveness)
    }

    func testColimaRunsWhenAnyProfilePidIsAlive() {
        let engine = colima { paths, liveness in
            paths.directories["/Users/test/.colima/_lima"] = ["_config", "colima", "colima-work"]
            paths.files["/Users/test/.colima/_lima/colima/ha.pid"] = "111\n"
            paths.files["/Users/test/.colima/_lima/colima-work/ha.pid"] = "222\n"
            liveness.alive = [222]
        }
        XCTAssertTrue(engine.isRunning())
    }

    func testColimaIsStoppedWhenThePidIsDead() {
        let engine = colima { paths, _ in
            paths.directories["/Users/test/.colima/_lima"] = ["colima"]
            paths.files["/Users/test/.colima/_lima/colima/ha.pid"] = "111"
        }
        XCTAssertFalse(engine.isRunning())
    }

    func testColimaIsStoppedWithoutAPidFileOrWithGarbageInIt() {
        XCTAssertFalse(colima { paths, _ in paths.directories["/Users/test/.colima/_lima"] = ["colima"] }.isRunning())
        XCTAssertFalse(colima { paths, liveness in
            paths.directories["/Users/test/.colima/_lima"] = ["colima"]
            paths.files["/Users/test/.colima/_lima/colima/ha.pid"] = "not-a-pid"
            liveness.alive = [0]
        }.isRunning())
        XCTAssertFalse(colima { _, _ in }.isRunning(), "no ~/.colima at all")
    }

    func testColimaIsInstalledByBinaryOrByItsHomeDirectory() {
        XCTAssertTrue(colima { paths, _ in paths.existing = ["/opt/homebrew/bin/colima"] }.isInstalled())
        XCTAssertTrue(colima { paths, _ in paths.existing = ["/usr/local/bin/colima"] }.isInstalled())
        XCTAssertTrue(colima { paths, _ in paths.existing = ["/Users/test/.colima"] }.isInstalled())
        XCTAssertFalse(colima { _, _ in }.isInstalled())
    }

    func testColimaName() {
        let engine = colima { _, _ in }
        XCTAssertEqual(engine.kind, .colima)
        XCTAssertEqual(engine.displayName, "colima")
    }

    // MARK: Docker Desktop

    private let socket = "/Users/test/.docker/run/docker.sock"

    func testDockerDesktopRunsWhenTheAppIsUpAndTheSocketAnswers() {
        let apps = FakeAppPresence(); apps.running = [DockerDesktopEngine.bundleID]
        let sockets = FakeSocketProbe(); sockets.connectable = [socket]
        XCTAssertTrue(DockerDesktopEngine(home: home, apps: apps, sockets: sockets).isRunning())
    }

    func testDockerDesktopIsStoppedWhenTheSocketIsSilent() {
        let apps = FakeAppPresence(); apps.running = [DockerDesktopEngine.bundleID]
        XCTAssertFalse(DockerDesktopEngine(home: home, apps: apps, sockets: FakeSocketProbe()).isRunning())
    }

    func testDockerDesktopDoesNotTouchTheSocketWhenTheAppIsNotRunning() {
        let sockets = FakeSocketProbe(); sockets.connectable = [socket]
        let engine = DockerDesktopEngine(home: home, apps: FakeAppPresence(), sockets: sockets)
        XCTAssertFalse(engine.isRunning())
        XCTAssertEqual(sockets.attempts, [])
    }

    func testDockerDesktopInstalledAndName() {
        let apps = FakeAppPresence(); apps.installed = [DockerDesktopEngine.bundleID]
        let engine = DockerDesktopEngine(home: home, apps: apps, sockets: FakeSocketProbe())
        XCTAssertTrue(engine.isInstalled())
        XCTAssertFalse(DockerDesktopEngine(home: home, apps: FakeAppPresence(), sockets: FakeSocketProbe()).isInstalled())
        XCTAssertEqual(engine.kind, .dockerDesktop)
        XCTAssertEqual(engine.displayName, "Docker Desktop")
    }
}