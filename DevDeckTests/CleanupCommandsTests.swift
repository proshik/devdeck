import XCTest
@testable import DevDeck

final class CleanupCommandsTests: XCTestCase {

    func testColimaCommandsRunInsideTheVMThroughSh() {
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

    func testRestartColimaBringsMinikubeBack() {
        // The minikube node container has restart policy `no`; a bare `colima restart` leaves it down.
        XCTAssertEqual(CleanupCommands.restartColima.command, "colima restart && minikube start")
        XCTAssertFalse(CleanupCommands.restartColima.isDaemon)
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
        XCTAssertTrue(seen.insert(CleanupCommands.restartColima.id).inserted)
        XCTAssertEqual(CleanupCommands.allIDs.count, seen.count)
        XCTAssertEqual(Set(CleanupCommands.allIDs), seen)
    }
}
