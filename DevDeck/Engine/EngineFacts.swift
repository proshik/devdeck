import Foundation

/// A VM data disk as the Mac sees it.
struct VMDiskFile: Equatable, Sendable {
    /// The colima profile's lima instance (`colima`, `colima-<profile>`).
    let instance: String
    let path: String
    /// Allocated, not logical: the file is sparse.
    let allocatedBytes: UInt64?
}

/// What the Cleanup page needs to know about the engines before it probes any daemon: which are
/// installed, which run, and what their disks take on the Mac. File reads, `kill(pid, 0)` and a
/// socket connect only — no process is spawned, so it is cheap enough for every page refresh.
struct EngineFacts: Equatable, Sendable {
    var colimaInstalled = false
    /// The default profile only — the one the page's colima commands reach.
    var colimaRunning = false
    var colimaDisks: [VMDiskFile] = []
    var dockerDesktopInstalled = false
    var dockerDesktopRunning = false
    var minikubeInstalled = false
    /// `Driver` of the default minikube profile, when its config is readable.
    var minikubeDriver: String?

    func isInstalled(_ host: DockerHost) -> Bool {
        switch host {
        case .colima: return colimaInstalled
        case .dockerDesktop: return dockerDesktopInstalled
        case .minikube: return minikubeInstalled
        }
    }

    /// Whether the daemon is worth probing. minikube has no cheap liveness signal — its probe's
    /// answer is the signal — so it is probed whenever it is installed.
    func shouldProbe(_ host: DockerHost) -> Bool {
        switch host {
        case .colima: return colimaInstalled && colimaRunning
        case .dockerDesktop: return dockerDesktopInstalled && dockerDesktopRunning
        case .minikube: return minikubeInstalled
        }
    }
}

protocol EngineFactsProbing: Sendable {
    func sample() -> EngineFacts
}

/// minikube is there when its binary or its home directory is.
struct MinikubePresence {
    static let binaryCandidates = ["/opt/homebrew/bin/minikube", "/usr/local/bin/minikube"]

    let home: String
    let paths: any PathProbing

    func isInstalled() -> Bool {
        Self.binaryCandidates.contains(where: paths.exists) || paths.exists(home + "/.minikube")
    }

    /// `"Driver": "docker"` from `~/.minikube/profiles/minikube/config.json`.
    func driver() -> String? {
        guard let text = paths.contents(ofFile: home + "/.minikube/profiles/minikube/config.json"),
              let data = text.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let driver = root["Driver"] as? String, !driver.isEmpty else { return nil }
        return driver
    }
}

struct LiveEngineFactsProbe: EngineFactsProbing {
    var home: String = NSHomeDirectory()
    var paths: any PathProbing = LivePathProbe()
    var reader: any DirectoryReading = LiveDirectoryReader()
    var colima: ColimaEngine?
    var dockerDesktop: (any ContainerEngine)?

    func sample() -> EngineFacts {
        let colima = self.colima ?? ColimaEngine(home: home, paths: paths)
        let desktop = dockerDesktop ?? DockerDesktopEngine(home: home)
        let minikube = MinikubePresence(home: home, paths: paths)
        var facts = EngineFacts()
        facts.colimaInstalled = colima.isInstalled()
        if facts.colimaInstalled {
            facts.colimaRunning = colima.isDefaultProfileRunning()
            facts.colimaDisks = colima.vmDiskFiles().map {
                VMDiskFile(instance: $0.instance, path: $0.path, allocatedBytes: reader.entry(at: $0.path)?.allocatedBytes)
            }
        }
        facts.dockerDesktopInstalled = desktop.isInstalled()
        facts.dockerDesktopRunning = facts.dockerDesktopInstalled && desktop.isRunning()
        facts.minikubeInstalled = minikube.isInstalled()
        if facts.minikubeInstalled { facts.minikubeDriver = minikube.driver() }
        return facts
    }
}
