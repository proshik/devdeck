import Foundation

/// A docker-level cleanup, the same three on either daemon. Each is deliberately conservative:
/// nothing here removes a named volume (databases, module caches) or a running container.
enum CleanupAction: String, CaseIterable, Sendable {
    /// Stopped containers plus the anonymous volumes nobody references any more — what
    /// testcontainers leaves behind when ryuk doesn't run.
    case deadContainers
    /// The whole BuildKit cache (`-a`, not just dangling layers). Costs one cold build.
    case buildCache
    /// Every image no container uses right now (`-a`). Can remove locally built images that a
    /// `imagePullPolicy: Never` pod needs on its next restart — the confirm says so.
    case unusedImages

    /// The docker CLI script, run inside the daemon's VM.
    var script: String {
        switch self {
        case .deadContainers: return "docker container prune -f && docker volume prune -f"
        case .buildCache: return "docker builder prune -a -f"
        case .unusedImages: return "docker image prune -a -f"
        }
    }
}

/// Cleanup as synthetic deck `Command`s: they run through the normal runner, so their output lands
/// in Logs and their run state in the shared state machine — no second process engine. IDs are
/// fixed so a re-created value keeps its state and log; none of these are ever persisted.
enum CleanupCommands {
    static func command(_ action: CleanupAction, on host: DockerHost) -> Command {
        Command(id: id(action, on: host),
                name: L10n.cleanupCommandName(action, host),
                command: host.wrap(action.script))
    }

    /// `colima restart` alone leaves the cluster down: the minikube node container has restart
    /// policy `no`, so it is started again explicitly. colima only — the page shows the button in
    /// the Colima section while its default profile runs.
    static func restartColima() -> Command {
        Command(id: restartEngineID, name: L10n.restartEngine("colima"), command: "colima restart && minikube start")
    }

    static let restartEngineID = UUID(uuidString: "C1EA0000-0000-4000-8000-0000000000FF")!

    /// Stop and remove the given test containers with the anonymous volumes they hold (`-v` never
    /// takes a named one). By id, not by label: the ids are the ones the page showed as abandoned,
    /// so a test run that started since the last refresh is not caught in it.
    static func removeTestContainers(ids: [String], on host: DockerHost) -> Command {
        Command(id: testContainersID(on: host),
                name: L10n.testContainersCommandName(host),
                command: host.wrap("docker rm -f -v " + ids.joined(separator: " ")))
    }

    static func testContainersID(on host: DockerHost) -> UUID {
        let hostDigit = DockerHost.allCases.firstIndex(of: host)! + 1
        return UUID(uuidString: "C1EA0000-0000-4000-8000-0000000001\(hostDigit)0")!
    }

    static func id(_ action: CleanupAction, on host: DockerHost) -> UUID {
        let hostDigit = DockerHost.allCases.firstIndex(of: host)! + 1
        let actionDigit = CleanupAction.allCases.firstIndex(of: action)! + 1
        return UUID(uuidString: "C1EA0000-0000-4000-8000-0000000000\(hostDigit)\(actionDigit)")!
    }

    /// Every id this namespace can produce — for "is any cleanup running" checks.
    static var allIDs: [UUID] {
        DockerHost.allCases.flatMap { host in CleanupAction.allCases.map { id($0, on: host) } + [testContainersID(on: host)] }
            + [restartEngineID, macFilesID]
    }

    // MARK: Mac files

    static let macFilesID = UUID(uuidString: "C1EA0000-0000-4000-8000-000000000200")!

    /// One command for everything the user confirmed, a step per path. The candidates have passed
    /// `DeletionGuard` just before; each step re-checks the cheap part of it in the shell — the
    /// directory is still a directory and not a link, its manifest is still next to it — so a swap
    /// in between is skipped, not followed. A failed step does not stop the others; the exit code
    /// says whether every one of them went through.
    static func removeMacFiles(_ candidates: [DiskCandidate]) -> Command {
        let steps = candidates.map(removalStep)
        let script = (["rc=0"] + steps + ["exit $rc"]).joined(separator: "\n")
        return Command(id: macFilesID, name: L10n.macFilesCommandName(count: candidates.count), command: script)
    }

    static func removalStep(_ candidate: DiskCandidate) -> String {
        let path = shellQuote(candidate.path)
        var guards = ["[ -d \(path) ]", "[ ! -L \(path) ]"]
        if let manifest = candidate.category.projectManifest {
            let parent = (candidate.path as NSString).deletingLastPathComponent
            guards.append("[ -f \(shellQuote(parent + "/" + manifest)) ]")
        }
        let action: String
        switch candidate.category.removal {
        case .directory:
            action = "rm -rf -- \(path)"
        case .contents:
            // find does not follow links (-P is its default); rm -rf on a link removes the link.
            action = "find \(path) -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +"
        case .goModCache:
            // go clean cleans whatever GOMODCACHE points at — only when that is the path shown.
            guards.append("[ \"$(go env GOMODCACHE 2>/dev/null)\" = \(path) ]")
            action = "go clean -modcache"
        }
        return "echo \(shellQuote("→ " + candidate.path))\n"
            + "if \(guards.joined(separator: " && ")); then \(action) || rc=1; "
            + "else echo 'skipped: no longer what the scan found'; rc=1; fi"
    }
}

extension DockerHost {
    /// Wrap a script so `zsh -lc` on the Mac runs it against this daemon. colima (lima)
    /// shell-escapes each argument, so the script travels through `sh -c` inside the VM; minikube
    /// joins its arguments verbatim, so the script must already be one quoted word. Docker
    /// Desktop's daemon is reached from the Mac: its socket in `DOCKER_HOST` (the shell expands
    /// `$HOME`), whatever docker context is current.
    func wrap(_ script: String) -> String {
        switch self {
        case .colima: return "colima ssh -- sh -c \(shellQuote(script))"
        case .minikube: return "minikube ssh -- \(shellQuote(script))"
        case .dockerDesktop:
            return "env DOCKER_HOST=\"unix://$HOME/.docker/run/docker.sock\" sh -c \(shellQuote(script))"
        }
    }
}
