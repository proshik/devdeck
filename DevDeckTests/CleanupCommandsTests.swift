import XCTest
@testable import DevDeck

final class CleanupCommandsTests: XCTestCase {

    func testEngineVMCommandsRunInsideColimaThroughSh() {
        // lima shell-escapes every argument, so `sh -c '<script>'` reaches the guest intact.
        XCTAssertEqual(CleanupCommands.command(.deadContainers, on: .engineVM, engineName: "colima").command,
                       "colima ssh -- sh -c 'docker container prune -f && docker volume prune -f'")
        XCTAssertEqual(CleanupCommands.command(.buildCache, on: .engineVM, engineName: "colima").command,
                       "colima ssh -- sh -c 'docker builder prune -a -f'")
        XCTAssertEqual(CleanupCommands.command(.unusedImages, on: .engineVM, engineName: "colima").command,
                       "colima ssh -- sh -c 'docker image prune -a -f'")
    }

    func testMinikubeCommandsPassOneScriptArgument() {
        // minikube joins its arguments verbatim, so the script travels as a single quoted word.
        XCTAssertEqual(CleanupCommands.command(.deadContainers, on: .minikube, engineName: "colima").command,
                       "minikube ssh -- 'docker container prune -f && docker volume prune -f'")
        XCTAssertEqual(CleanupCommands.command(.buildCache, on: .minikube, engineName: "colima").command,
                       "minikube ssh -- 'docker builder prune -a -f'")
        XCTAssertEqual(CleanupCommands.command(.unusedImages, on: .minikube, engineName: "colima").command,
                       "minikube ssh -- 'docker image prune -a -f'")
    }

    func testNamedVolumesAreNeverTouched() {
        // `docker volume prune` without `-a` removes anonymous volumes only — pgdata & caches survive.
        for host in DockerHost.allCases {
            let c = CleanupCommands.command(.deadContainers, on: host, engineName: "colima").command
            XCTAssertTrue(c.contains("docker volume prune -f"), c)
            XCTAssertFalse(c.contains("volume prune -a"), c)
            XCTAssertFalse(c.contains("volume prune -f -a"), c)
        }
    }

    func testRestartEngineBringsMinikubeBack() {
        // The minikube node container has restart policy `no`; a bare `colima restart` leaves it down.
        XCTAssertEqual(CleanupCommands.restartEngine(engineName: "colima").command, "colima restart && minikube start")
        XCTAssertFalse(CleanupCommands.restartEngine(engineName: "colima").isDaemon)
    }

    func testIDsAreStableAndDistinct() {
        var seen: Set<UUID> = []
        for host in DockerHost.allCases {
            for action in CleanupAction.allCases {
                let a = CleanupCommands.command(action, on: host, engineName: "colima")
                let b = CleanupCommands.command(action, on: host, engineName: "colima")
                XCTAssertEqual(a.id, b.id, "id must be stable across re-creation")
                XCTAssertTrue(seen.insert(a.id).inserted, "id must be unique per (action, host)")
                XCTAssertFalse(a.isDaemon)
                XCTAssertFalse(a.needsSudo)
                XCTAssertFalse(a.openInTerminal)
                XCTAssertFalse(a.name.isEmpty)
            }
        }
        XCTAssertTrue(seen.insert(CleanupCommands.restartEngine(engineName: "colima").id).inserted)
        XCTAssertEqual(CleanupCommands.allIDs.count, seen.count)
        XCTAssertEqual(Set(CleanupCommands.allIDs), seen)
    }

    /// The ids are what ties a cleanup's run state and log across re-creations. They derive from
    /// the position in `DockerHost.allCases`, so renaming a case is fine and reordering is not.
    func testIDsArePinned() {
        let expected: [(CleanupAction, DockerHost, String)] = [
            (.deadContainers, .engineVM, "C1EA0000-0000-4000-8000-000000000011"),
            (.buildCache, .engineVM, "C1EA0000-0000-4000-8000-000000000012"),
            (.unusedImages, .engineVM, "C1EA0000-0000-4000-8000-000000000013"),
            (.deadContainers, .minikube, "C1EA0000-0000-4000-8000-000000000021"),
            (.buildCache, .minikube, "C1EA0000-0000-4000-8000-000000000022"),
            (.unusedImages, .minikube, "C1EA0000-0000-4000-8000-000000000023"),
        ]
        for (action, host, uuid) in expected {
            XCTAssertEqual(CleanupCommands.id(action, on: host).uuidString, uuid, "\(action) on \(host)")
        }
        XCTAssertEqual(CleanupCommands.restartEngineID.uuidString, "C1EA0000-0000-4000-8000-0000000000FF")
    }

    func testCommandNamesShowTheEngineNotTheCaseName() {
        let name = CleanupCommands.command(.buildCache, on: .engineVM, engineName: "Docker Desktop").name
        XCTAssertTrue(name.contains("Docker Desktop"), name)
        XCTAssertFalse(name.contains("engineVM"), name)
        XCTAssertTrue(CleanupCommands.command(.buildCache, on: .minikube, engineName: "colima").name.contains("minikube"))
        XCTAssertTrue(CleanupCommands.restartEngine(engineName: "colima").name.contains("colima"))
    }
}