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

    // MARK: selector

    private func select(_ preference: EnginePreference, _ engines: FakeEngine...) -> EngineChoice? {
        EngineSelector.select(preference, from: engines)
    }

    func testAutoPicksTheRunningEngine() {
        let choice = select(.auto, FakeEngine(.colima), FakeEngine(.dockerDesktop, running: true))
        XCTAssertEqual(choice?.engine.kind, .dockerDesktop)
        XCTAssertEqual(choice?.running, true)
    }

    func testAutoPrefersColimaWhenBothRun() {
        let choice = select(.auto, FakeEngine(.colima, running: true), FakeEngine(.dockerDesktop, running: true))
        XCTAssertEqual(choice?.engine.kind, .colima)
    }

    func testAutoFallsBackToAnInstalledEngineWhenNothingRuns() {
        XCTAssertEqual(select(.auto, FakeEngine(.colima), FakeEngine(.dockerDesktop))?.engine.kind, .colima,
                       "both installed → colima first")
        let onlyDesktop = select(.auto, FakeEngine(.colima, installed: false), FakeEngine(.dockerDesktop))
        XCTAssertEqual(onlyDesktop?.engine.kind, .dockerDesktop)
        XCTAssertEqual(onlyDesktop?.running, false)
    }

    func testAutoFindsNothingWhenNothingIsInstalled() {
        XCTAssertNil(select(.auto, FakeEngine(.colima, installed: false), FakeEngine(.dockerDesktop, installed: false)))
    }

    func testExplicitPreferenceOverridesDetectionEvenWhenNotInstalled() {
        let choice = select(.dockerDesktop, FakeEngine(.colima, running: true),
                            FakeEngine(.dockerDesktop, installed: false))
        XCTAssertEqual(choice?.engine.kind, .dockerDesktop)
        XCTAssertEqual(choice?.running, false)
    }

    // MARK: model

    @MainActor
    func testModelFollowsThePreferenceAndTheRunningState() {
        let colima = FakeEngine(.colima, running: true)
        let desktop = FakeEngine(.dockerDesktop)
        let model = EngineModel(candidates: [colima, desktop])
        var preference = EnginePreference.auto
        model.preference = { preference }

        model.refresh()
        XCTAssertEqual(model.activeKind, .colima)
        XCTAssertEqual(model.activeName, "colima")
        XCTAssertTrue(model.isActiveRunning)

        colima.running = false
        model.refresh()
        XCTAssertEqual(model.activeKind, .colima, "still installed")
        XCTAssertFalse(model.isActiveRunning)

        preference = .dockerDesktop
        model.refresh()
        XCTAssertEqual(model.activeKind, .dockerDesktop)
        XCTAssertEqual(model.activeName, "Docker Desktop")
    }

    @MainActor
    func testModelStartsEmpty() {
        let model = EngineModel(candidates: [FakeEngine(.colima, running: true)])
        XCTAssertNil(model.activeKind, "nothing is known before the first refresh")
        XCTAssertFalse(model.isActiveRunning)
    }
}