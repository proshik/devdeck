import Foundation

/// colima is up when a lima host agent is alive: `~/.colima/_lima/<instance>/ha.pid` holds its pid.
/// The `default` profile is the lima instance `colima`, any other profile `colima-<name>`; the
/// directory also holds `_config`/`_networks`, which simply have no `ha.pid`.
struct ColimaEngine: ContainerEngine {
    static let binaryCandidates = ["/opt/homebrew/bin/colima", "/usr/local/bin/colima"]

    let kind = ContainerEngineKind.colima
    let displayName = "colima"

    private let home: String
    private let paths: any PathProbing
    private let liveness: any ProcessLivenessChecking

    init(home: String = NSHomeDirectory(), paths: any PathProbing = LivePathProbe(),
         liveness: any ProcessLivenessChecking = LiveProcessLiveness()) {
        self.home = home
        self.paths = paths
        self.liveness = liveness
    }

    func isInstalled() -> Bool {
        Self.binaryCandidates.contains(where: paths.exists) || paths.exists(home + "/.colima")
    }

    func isRunning() -> Bool {
        let lima = home + "/.colima/_lima"
        return paths.directoryEntries(at: lima).contains { instance in
            guard let text = paths.contents(ofFile: "\(lima)/\(instance)/ha.pid"),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return liveness.isAlive(pid: pid)
        }
    }
}