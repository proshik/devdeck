import XCTest
@testable import DevDeck

final class CleanupCommandsTests: XCTestCase {

    func testEngineVMCommandsRunInsideColimaThroughSh() {
        // lima shell-escapes every argument, so `sh -c '<script>'` reaches the guest intact.
        XCTAssertEqual(CleanupCommands.command(.deadContainers, on: .colima).command,
                       "colima ssh -- sh -c 'docker container prune -f && docker volume prune -f'")
        XCTAssertEqual(CleanupCommands.command(.buildCache, on: .colima).command,
                       "colima ssh -- sh -c 'docker builder prune -a -f'")
        XCTAssertEqual(CleanupCommands.command(.unusedImages, on: .colima).command,
                       "colima ssh -- sh -c 'docker image prune -a -f'")
    }

    func testMinikubeCommandsPassOneScriptArgument() {
        // minikube joins its arguments verbatim, so the script travels as a single quoted word.
        XCTAssertEqual(CleanupCommands.command(.deadContainers, on: .minikube).command,
                       "minikube ssh -- 'docker container prune -f && docker volume prune -f'")
        XCTAssertEqual(CleanupCommands.command(.buildCache, on: .minikube).command,
                       "minikube ssh -- 'docker builder prune -a -f'")
        XCTAssertEqual(CleanupCommands.command(.unusedImages, on: .minikube).command,
                       "minikube ssh -- 'docker image prune -a -f'")
    }

    func testNamedVolumesAreNeverTouched() {
        // `docker volume prune` without `-a` removes anonymous volumes only — pgdata & caches survive.
        for host in DockerHost.allCases {
            let c = CleanupCommands.command(.deadContainers, on: host).command
            XCTAssertTrue(c.contains("docker volume prune -f"), c)
            XCTAssertFalse(c.contains("volume prune -a"), c)
            XCTAssertFalse(c.contains("volume prune -f -a"), c)
        }
    }

    func testRestartEngineBringsMinikubeBack() {
        // The minikube node container has restart policy `no`; a bare `colima restart` leaves it down.
        XCTAssertEqual(CleanupCommands.restartColima().command, "colima restart && minikube start")
        XCTAssertFalse(CleanupCommands.restartColima().isDaemon)
    }

    func testIDsAreStableAndDistinct() {
        var seen: Set<UUID> = []
        for host in DockerHost.allCases {
            for action in CleanupAction.allCases {
                let a = CleanupCommands.command(action, on: host)
                let b = CleanupCommands.command(action, on: host)
                XCTAssertEqual(a.id, b.id, "id must be stable across re-creation")
                XCTAssertTrue(seen.insert(a.id).inserted, "id must be unique per (action, host)")
                XCTAssertFalse(a.isDaemon)
                XCTAssertFalse(a.needsSudo)
                XCTAssertFalse(a.openInTerminal)
                XCTAssertFalse(a.name.isEmpty)
            }
        }
        XCTAssertTrue(seen.insert(CleanupCommands.restartColima().id).inserted)
        for host in DockerHost.allCases {
            let t = CleanupCommands.removeTestContainers(ids: ["x"], on: host)
            XCTAssertTrue(seen.insert(t.id).inserted, "test-container removal must not share an id")
            XCTAssertFalse(t.isDaemon)
        }
        XCTAssertTrue(seen.insert(CleanupCommands.macFilesID).inserted, "the Mac-files deletion has its own id")
        XCTAssertEqual(CleanupCommands.allIDs.count, seen.count)
        XCTAssertEqual(Set(CleanupCommands.allIDs), seen)
    }

    /// The ids are what ties a cleanup's run state and log across re-creations. They derive from
    /// the position in `DockerHost.allCases`, so renaming a case is fine and reordering is not.
    func testIDsArePinned() {
        let expected: [(CleanupAction, DockerHost, String)] = [
            (.deadContainers, .colima, "C1EA0000-0000-4000-8000-000000000011"),
            (.buildCache, .colima, "C1EA0000-0000-4000-8000-000000000012"),
            (.unusedImages, .colima, "C1EA0000-0000-4000-8000-000000000013"),
            (.deadContainers, .minikube, "C1EA0000-0000-4000-8000-000000000021"),
            (.buildCache, .minikube, "C1EA0000-0000-4000-8000-000000000022"),
            (.unusedImages, .minikube, "C1EA0000-0000-4000-8000-000000000023"),
            (.deadContainers, .dockerDesktop, "C1EA0000-0000-4000-8000-000000000031"),
            (.buildCache, .dockerDesktop, "C1EA0000-0000-4000-8000-000000000032"),
            (.unusedImages, .dockerDesktop, "C1EA0000-0000-4000-8000-000000000033"),
        ]
        for (action, host, uuid) in expected {
            XCTAssertEqual(CleanupCommands.id(action, on: host).uuidString, uuid, "\(action) on \(host)")
        }
        XCTAssertEqual(CleanupCommands.restartEngineID.uuidString, "C1EA0000-0000-4000-8000-0000000000FF")
        XCTAssertEqual(CleanupCommands.macFilesID.uuidString, "C1EA0000-0000-4000-8000-000000000200")
    }

    func testCommandNamesShowTheEngineNotTheCaseName() {
        XCTAssertTrue(CleanupCommands.command(.buildCache, on: .dockerDesktop).name.contains("Docker Desktop"))
        XCTAssertFalse(CleanupCommands.command(.buildCache, on: .dockerDesktop).name.contains("dockerDesktop"))
        XCTAssertTrue(CleanupCommands.command(.buildCache, on: .colima).name.contains("colima"))
        XCTAssertTrue(CleanupCommands.command(.buildCache, on: .minikube).name.contains("minikube"))
        XCTAssertTrue(CleanupCommands.restartColima().name.contains("colima"))
    }

    // MARK: - test containers

    func testRemovingTestContainersNamesThemAndTakesTheirAnonymousVolumes() {
        let colima = CleanupCommands.removeTestContainers(ids: ["aaa111", "bbb222"], on: .colima)
        XCTAssertEqual(colima.command, "colima ssh -- sh -c 'docker rm -f -v aaa111 bbb222'")
        XCTAssertEqual(colima.id, CleanupCommands.testContainersID(on: .colima))
        let minikube = CleanupCommands.removeTestContainers(ids: ["aaa111"], on: .minikube)
        XCTAssertEqual(minikube.command, "minikube ssh -- 'docker rm -f -v aaa111'")
    }

    // MARK: - Docker Desktop

    /// Its daemon is reached from the Mac: the docker CLI with DOCKER_HOST on its socket, whatever
    /// docker context is current.
    func testDockerDesktopCommandsTalkToItsSocketFromTheMac() {
        let prefix = "env -u DOCKER_CONTEXT -u BUILDX_BUILDER DOCKER_HOST=\"unix://$HOME/.docker/run/docker.sock\" "
            + "PATH=\"/Applications/Docker.app/Contents/Resources/bin:$PATH\" sh -c "
        XCTAssertEqual(CleanupCommands.command(.buildCache, on: .dockerDesktop).command,
                       prefix + "'docker builder prune -a -f'",
                       "a remote Buildx builder or another context must never receive the prune")
        XCTAssertEqual(CleanupCommands.removeTestContainers(ids: ["a1"], on: .dockerDesktop).command,
                       prefix + "'docker rm -f -v a1'")
    }

    func testTestContainerIDsArePinned() {
        XCTAssertEqual(CleanupCommands.testContainersID(on: .colima).uuidString, "C1EA0000-0000-4000-8000-000000000110")
        XCTAssertEqual(CleanupCommands.testContainersID(on: .minikube).uuidString, "C1EA0000-0000-4000-8000-000000000120")
        XCTAssertEqual(CleanupCommands.testContainersID(on: .dockerDesktop).uuidString, "C1EA0000-0000-4000-8000-000000000130")
    }
}