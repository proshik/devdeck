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
    /// Anonymous volumes no *running* container holds, by size — what `docker volume prune` frees
    /// once `docker container prune` has removed the stopped containers still linking them. docker's
    /// own `Local Volumes` reclaimable figure answers a different question (what is unreferenced
    /// *right now*, named volumes included), so it is both blind to a testcontainers backlog and
    /// generous about named volumes the button never deletes. nil when the listing was absent or
    /// unreadable → the estimate falls back to docker's figure.
    var pruneableVolumeBytes: UInt64?
    /// Size of the volume that carries the *other* daemon: minikube keeps its node's entire docker
    /// inside one volume on the colima disk, so colima counts the whole cluster as one of its own
    /// volumes. Named apart, or the page's two boxes look like they double-count the same bytes.
    /// nil when the listing was absent, 0 when there is no such volume (inside the node itself).
    var nestedDaemonVolumeBytes: UInt64?
    /// The unique layers of the images no container references — what `docker image prune -a`
    /// actually frees. docker's own `Images` reclaimable figure counts layers shared with images
    /// that *are* in use, and inside the minikube node (docker 29.2.1) it reports 100% reclaimable
    /// while every image is held by a container: the button then promised gigabytes and freed
    /// nothing. nil when the listing was absent → the estimate falls back to docker's figure.
    var pruneableImageBytes: UInt64?

    /// Separates the probe script's three outputs. Not a string docker itself can print.
    static let sectionMarker = "---devdeck---"

    /// Parse the probe output: the `docker system df --format '{{json .}}'` rows, and — when the
    /// script also carried them — the volume listing and the volumes running containers hold.
    /// nil when not a single known summary row parses (daemon down, error text).
    static func parse(_ output: String) -> DockerUsage? {
        let sections = output.components(separatedBy: sectionMarker)
        guard var usage = parseSummary(sections[0]) else { return nil }
        if sections.count >= 3,
           let detail = parseDetail(sections[1], heldByRunning: volumeNames(sections[2])) {
            usage.pruneableVolumeBytes = detail.pruneableVolumeBytes
            usage.nestedDaemonVolumeBytes = detail.nestedDaemonBytes
            usage.pruneableImageBytes = detail.pruneableImageBytes
        }
        return usage
    }

    /// The `{{json .}}` summary rows — one JSON object per line, keyed by `Type`.
    static func parseSummary(_ output: String) -> DockerUsage? {
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

    /// What the verbose listing yields, decoded in one pass.
    struct Detail: Equatable, Sendable {
        let pruneableVolumeBytes: UInt64
        let nestedDaemonBytes: UInt64
        let pruneableImageBytes: UInt64
    }

    /// Read `docker system df -v --format '{{json .}}'` — the one call that carries per-item sizes:
    /// the anonymous volumes `docker volume prune` will take once the stopped containers are gone
    /// (everything with docker's anonymous label that none of `heldByRunning` holds), the nested
    /// daemon's own volume, and the unique layers of the images no container references. nil when
    /// the listing didn't decode — a fallback is honest, a zero would read as "nothing here".
    static func parseDetail(_ json: String, heldByRunning: Set<String>) -> Detail? {
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let volumes = root["Volumes"] as? [[String: Any]],
              let images = root["Images"] as? [[String: Any]]
        else { return nil }

        var pruneableVolumes: UInt64 = 0
        var nested: UInt64 = 0
        for volume in volumes {
            guard let name = volume["Name"] as? String,
                  let labels = volume["Labels"] as? String,
                  let size = (volume["Size"] as? String).flatMap(parseSize)
            else { continue }
            let keys = labelKeys(labels)
            if keys.contains("created_by.minikube.sigs.k8s.io") { nested += size }
            if keys.contains("com.docker.volume.anonymous"), !heldByRunning.contains(name) {
                pruneableVolumes += size
            }
        }

        // Only the layers that image alone owns: an unused image sharing its base with one that is
        // still in use frees just its own bytes. A layer two removable images share is left out of
        // both, so the figure is a floor — a cleanup button may under-promise, never over-promise.
        var pruneableImages: UInt64 = 0
        for image in images where image["Containers"] as? String == "0" {
            guard let unique = (image["UniqueSize"] as? String).flatMap(parseSize) else { continue }
            pruneableImages += unique
        }

        return Detail(pruneableVolumeBytes: pruneableVolumes,
                      nestedDaemonBytes: nested,
                      pruneableImageBytes: pruneableImages)
    }

    /// The label keys of a `k=v,k=v` listing. docker labels every volume it created for a container
    /// itself — `docker volume prune` without `-a` removes only those, so a named volume (a
    /// database, a module cache) is never counted as free space.
    static func labelKeys(_ labels: String) -> [Substring] {
        labels.split(separator: ",").compactMap { $0.split(separator: "=", maxSplits: 1).first }
    }

    /// One volume name per line, blank lines dropped — `docker inspect` prints a gap per container.
    static func volumeNames(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
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

    /// What a cleanup action can free. Build cache and images take docker's own reclaimable figure;
    /// dead containers take their writable layers plus the volumes only they still hold, since the
    /// action prunes the containers first and docker's figure cannot see past that.
    func estimate(for action: CleanupAction) -> UInt64? {
        switch action {
        case .deadContainers:
            guard let containers else { return nil }
            if let pruneableVolumeBytes { return containers.reclaimableBytes + pruneableVolumeBytes }
            guard let volumes else { return nil }
            return containers.reclaimableBytes + volumes.reclaimableBytes
        case .buildCache:
            return buildCache?.reclaimableBytes
        case .unusedImages:
            return pruneableImageBytes ?? images?.reclaimableBytes
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
/// depends on the host docker CLI or its current context. Blocking and not cheap — the verbose
/// pass walks every volume, seconds rather than milliseconds on a full disk → call off-main.
/// Daemon down → nil.
struct LiveDockerUsageProbe: DockerUsageProbing {
    /// Three outputs behind `DockerUsage.sectionMarker`: the summary rows, the verbose listing
    /// (the only one carrying per-item sizes, hence one `-v` pass for both volumes and images), and
    /// the volumes running containers hold — the last two are what separate a volume a stopped
    /// container merely links from one still in use. Kept on a single line: minikube hands the
    /// script to its remote shell as one word.
    private static let script = """
    docker system df --format '{{json .}}'; echo '\(DockerUsage.sectionMarker)'; \
    docker system df -v --format '{{json .}}'; echo '\(DockerUsage.sectionMarker)'; \
    docker ps -q | xargs -r docker inspect \
    -f '{{range .Mounts}}{{if eq .Type "volume"}}{{println .Name}}{{end}}{{end}}'
    """

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
