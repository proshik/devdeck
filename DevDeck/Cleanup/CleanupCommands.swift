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
    /// policy `no`, so it is started again explicitly.
    static var restartColima: Command {
        Command(id: restartColimaID, name: L10n.restartColima, command: "colima restart && minikube start")
    }

    static let restartColimaID = UUID(uuidString: "C1EA0000-0000-4000-8000-0000000000FF")!

    static func id(_ action: CleanupAction, on host: DockerHost) -> UUID {
        let hostDigit = DockerHost.allCases.firstIndex(of: host)! + 1
        let actionDigit = CleanupAction.allCases.firstIndex(of: action)! + 1
        return UUID(uuidString: "C1EA0000-0000-4000-8000-0000000000\(hostDigit)\(actionDigit)")!
    }

    /// Every id this namespace can produce — for "is any cleanup running" checks.
    static var allIDs: [UUID] {
        DockerHost.allCases.flatMap { host in CleanupAction.allCases.map { id($0, on: host) } } + [restartColimaID]
    }
}

extension DockerHost {
    /// Wrap a script so `zsh -lc` on the Mac runs it inside this daemon's VM. colima (lima)
    /// shell-escapes each argument, so the script travels through `sh -c`; minikube joins its
    /// arguments verbatim, so the script must already be one quoted word.
    func wrap(_ script: String) -> String {
        switch self {
        case .colima: return "colima ssh -- sh -c \(shellQuote(script))"
        case .minikube: return "minikube ssh -- \(shellQuote(script))"
        }
    }
}
