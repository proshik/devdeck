import Foundation

// MARK: - DockerHost

/// Which docker daemon a figure or a cleanup refers to: the colima VM's own, or the one inside
/// the minikube node container — where `minikube docker-env` builds and the cluster's images live,
/// all of it inside the single `minikube` volume on the colima disk.
enum DockerHost: String, CaseIterable, Hashable, Sendable {
    case colima, minikube
}

// MARK: - DockerUsage

/// One `docker system df` row: count, in-use count, size, and what docker itself calls reclaimable.
struct DockerUsageRow: Equatable, Sendable {
    let total: Int
    let active: Int
    let sizeBytes: UInt64
    let reclaimableBytes: UInt64
}

/// Parsed `docker system df` for one daemon. Rows are optional: docker only prints the types it
/// knows, and a partially garbled listing still shows what it could.
struct DockerUsage: Equatable, Sendable {
    var images: DockerUsageRow?
    var containers: DockerUsageRow?
    var volumes: DockerUsageRow?
    var buildCache: DockerUsageRow?

    /// Parse `docker system df --format '{{json .}}'` — one JSON object per line, keyed by `Type`.
    /// nil when not a single known row parses (daemon down, error text).
    static func parse(_ output: String) -> DockerUsage? {
        var usage = DockerUsage()
        var any = false
        for line in output.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let type = obj["Type"] as? String,
                  let total = (obj["TotalCount"] as? String).flatMap(Int.init),
                  let active = (obj["Active"] as? String).flatMap(Int.init),
                  let size = (obj["Size"] as? String).flatMap(parseSize),
                  let reclaimable = (obj["Reclaimable"] as? String).flatMap(parseSize)
            else { continue }
            let row = DockerUsageRow(total: total, active: active, sizeBytes: size, reclaimableBytes: reclaimable)
            switch type {
            case "Images": usage.images = row
            case "Containers": usage.containers = row
            case "Local Volumes": usage.volumes = row
            case "Build Cache": usage.buildCache = row
            default: continue
            }
            any = true
        }
        return any ? usage : nil
    }

    /// docker's go-units sizes are decimal ("9.617GB (57%)", "177.4MB", "0B"); the parenthesised
    /// percentage is ignored. nil for anything else — including a bare number without a unit.
    static func parseSize(_ text: String) -> UInt64? {
        guard let token = text.split(separator: " ", omittingEmptySubsequences: true).first else { return nil }
        let units: [(String, Double)] = [("PB", 1e15), ("TB", 1e12), ("GB", 1e9), ("MB", 1e6), ("kB", 1e3), ("B", 1)]
        for (suffix, factor) in units where token.hasSuffix(suffix) {
            guard let value = Double(token.dropLast(suffix.count)), value >= 0 else { return nil }
            return UInt64((value * factor).rounded())
        }
        return nil
    }

    /// What a cleanup action can free, from docker's own reclaimable figures. A lower bound for
    /// dead containers: the anonymous volumes they hold only become reclaimable once they're gone.
    func estimate(for action: CleanupAction) -> UInt64? {
        switch action {
        case .deadContainers:
            guard let containers, let volumes else { return nil }
            return containers.reclaimableBytes + volumes.reclaimableBytes
        case .buildCache:
            return buildCache?.reclaimableBytes
        case .unusedImages:
            return images?.reclaimableBytes
        }
    }

    /// "1.2 GB" / "324 MB" — binary units, the same scale as the popover's disk cell.
    static func formatBytes(_ bytes: UInt64) -> String {
        let gib = 1_073_741_824.0
        let mib = 1_048_576.0
        if Double(bytes) >= gib { return String(format: "%.1f GB", Double(bytes) / gib) }
        return String(format: "%.0f MB", Double(bytes) / mib)
    }
}

// MARK: - Probe

/// Behind a protocol → `CleanupModel` is tested with a fake (no ssh, no docker).
protocol DockerUsageProbing: Sendable {
    func sample(_ host: DockerHost) -> DockerUsage?
}

/// The real probe: `docker system df` run inside the daemon's own VM over ssh, so it never
/// depends on the host docker CLI or its current context. Blocking (~0.3 s colima, ~0.6 s
/// minikube) → call off-main. Daemon down → nil.
struct LiveDockerUsageProbe: DockerUsageProbing {
    private static let script = "docker system df --format '{{json .}}'"

    func sample(_ host: DockerHost) -> DockerUsage? {
        let (binary, args) = Self.invocation(host)
        let out = ProcessTree.run("/opt/homebrew/bin/\(binary)", args)
            ?? ProcessTree.run("/usr/bin/env", [binary] + args)
        return out.flatMap(DockerUsage.parse)
    }

    /// colima (lima) shell-escapes each argument → `sh -c <script>` is safe; minikube joins its
    /// arguments verbatim → the script must already be one argument.
    static func invocation(_ host: DockerHost) -> (binary: String, args: [String]) {
        switch host {
        case .colima: return ("colima", ["ssh", "--", "sh", "-c", script])
        case .minikube: return ("minikube", ["ssh", "--", script])
        }
    }
}
