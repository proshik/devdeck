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
    /// `DeletionGuard` just before; each step repeats the guard in the shell at the moment it runs,
    /// so a change in between is skipped, not followed. A failed step does not stop the others;
    /// the exit code says whether every one of them went through. `device` is the home folder's
    /// volume as the guard saw it — every step and every operand must still be on it. `skipped`
    /// are the paths the last check turned away, named in the log with their reason.
    static func removeMacFiles(_ candidates: [DiskCandidate], device: UInt64,
                               skipped: [(path: String, reason: String)] = []) -> Command {
        let notes = skipped.map { "echo \(shellQuote("skipped: \($0.path) — \($0.reason)"))" }
        let steps = candidates.map { removalStep($0, device: device) }
        let script = (["rc=0"] + notes + steps + ["exit $rc"]).joined(separator: "\n")
        return Command(id: macFilesID, name: L10n.macFilesCommandName(count: candidates.count), command: script)
    }

    /// A step runs in its own subshell and is anchored before it deletes anything: it `cd -P`s
    /// into the directory it acts on (or its parent) and requires the physical working directory
    /// to be exactly the confirmed path — so no component, the last or any ancestor, may have
    /// become a link since — and to be on the confirmed volume. It then deletes by a name relative
    /// to that working directory, which a later swap of an ancestor cannot redirect. `rm -x`
    /// never crosses into another mounted volume, and an entry on another device is never handed
    /// to `rm` at all. The scan's project-root rule (no `.git` inside, no `Cargo.toml` inside a
    /// target) is checked again here — APFS resolves `.GIT` too — and so is cargo's build lock.
    ///
    /// What the shell cannot close: a concurrent rename of the leaf itself between its checks and
    /// `rm` opening it (design §5.7, known limits).
    static func removalStep(_ candidate: DiskCandidate, device: UInt64) -> String {
        let skipped = "echo 'skipped: no longer what the scan found'; exit 1"
        let dev = shellQuote(String(device))
        let body: String
        switch candidate.category.removal {
        case .directory:
            let parent = (candidate.path as NSString).deletingLastPathComponent
            let name = shellQuote((candidate.path as NSString).lastPathComponent)
            var checks = ["[ -d \(name) ]", "[ ! -L \(name) ]", "[ ! -e \(name)/.git ]",
                          "[ \"$(/usr/bin/stat -f %d \(name))\" = \(dev) ]"]
            if let manifest = candidate.category.projectManifest {
                checks.append("[ -f \(shellQuote(manifest)) ]")
            }
            var lockCheck = ""
            if candidate.category == .rustTarget {
                checks.append("[ ! -e \(name)/Cargo.toml ]")
                // cargo holds a flock on <target>/<profile>/.cargo-lock for a whole build; -k keeps
                // the file, -t 0 does not wait, exit 75 means it is held.
                lockCheck = "for l in \(name)/*/.cargo-lock(N); do /usr/bin/lockf -kns -t 0 \"$l\" true "
                    + "|| { echo 'skipped: a cargo build is running'; exit 1; }; done; "
            }
            body = anchor(parent, device: dev) + lockCheck
                + "if \(checks.joined(separator: " && ")); then /bin/rm -rfx -- \(name); else \(skipped); fi"
        case .contents:
            // Everything inside, dot-files included (zsh: D), nothing when empty (N); the folder
            // stays. An unlistable folder would glob to nothing and look emptied — it fails instead.
            body = anchor(candidate.path, device: dev)
                + "[ -r . ] || { echo 'failed: the folder cannot be listed'; exit 1; }; "
                + "r=0; for e in ./*(DN); do "
                + "if ! d=$(/usr/bin/stat -f %d \"$e\"); then echo \"failed to inspect: $e\"; r=1; "
                + "elif [ \"$d\" = \(dev) ]; then /bin/rm -rfx -- \"$e\" || r=1; "
                + "else echo \"skipped, another volume: $e\"; fi; done; exit $r"
        case .goModCache:
            // Module files are read-only; go clean handles that. Only when Go's own cache is the
            // confirmed path (design §5.5); GOMODCACHE then pins it whatever changes meanwhile, and
            // a non-empty GOFLAGS replaces an inherited one (`-cache` would clear the build cache).
            let path = shellQuote(candidate.path)
            body = anchor(candidate.path, device: dev)
                + "g=$(go env GOMODCACHE && echo .) && [ \"${g%??}\" = \(path) ] "
                + "|| { echo 'skipped: go env GOMODCACHE is not this folder'; exit 1; }; "
                + "cd .. && GOMODCACHE=\(path) GOFLAGS=-modcacherw go clean -modcache"
        }
        return "echo \(shellQuote("→ " + candidate.path))\n( \(body) ) || rc=1"
    }

    /// Enter `path` without following any link on the way and stop unless it is exactly `path` on
    /// the confirmed volume. `$(…)` drops trailing newlines, so a sentinel after `pwd -P` keeps
    /// them: a name ending in a newline compares as itself, not as its neighbour without one.
    private static func anchor(_ path: String, device dev: String) -> String {
        let quoted = shellQuote(path)
        return "cd -P -- \(quoted) 2>/dev/null && p=$(pwd -P && echo .) && [ \"${p%??}\" = \(quoted) ] "
            + "&& [ \"$(/usr/bin/stat -f %d .)\" = \(dev) ] "
            + "|| { echo 'skipped: no longer what the scan found'; exit 1; }; "
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
            // Its own CLI first on PATH (the login shell may know no other docker), and nothing
            // inherited or saved may point the CLI elsewhere: no context, and Buildx's `default`
            // builder — the one of DOCKER_HOST's daemon — over any builder `buildx use` remembered.
            return "env -u DOCKER_CONTEXT BUILDX_BUILDER=default DOCKER_HOST=\"unix://$HOME/.docker/run/docker.sock\" "
                + "PATH=\"\(LiveDockerUsageProbe.dockerDesktopBin):$PATH\" sh -c \(shellQuote(script))"
        }
    }
}
