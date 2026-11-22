import Darwin
import Foundation

/// What the guard needs from the file system beyond listing it.
protocol DeletionInspecting: DirectoryReading {
    /// `realpath(3)`: nil when the path cannot be resolved.
    func realPath(_ path: String) -> String?
    /// Whether another process holds a `flock` on this file right now.
    func isLockHeld(_ path: String) -> Bool
}

/// Why a candidate is not deleted. Shown in the confirmation next to the path.
enum DeletionRejection: Equatable, Sendable {
    case outsideHome, missing, notADirectory, symlink, symlinkedAncestor, otherVolume
    /// It no longer is what the scan saw: the manifest is gone, or a project sits inside it.
    case noLongerMatches
    /// cargo holds the build directory's lock — a build is running in it.
    case buildRunning
}

/// The last check before anything is deleted, run when the confirmation opens and again on
/// "Delete". A scan can be days old; the path it found may since have become a symlink, lost its
/// `Cargo.toml` or be in the middle of a build. Every rule must pass — the shell steps of the
/// command repeat the cheap ones as a second line against a change in between.
struct DeletionGuard {
    let inspector: any DeletionInspecting
    /// The scanned root, already resolved (`realpath`) — the home folder.
    let root: String

    func check(_ candidate: DiskCandidate) -> DeletionRejection? {
        let path = candidate.path
        guard Self.isPlainAbsolute(path), path.hasPrefix(root + "/"), path != root else { return .outsideHome }
        guard matchesCategoryPath(candidate) else { return .noLongerMatches }
        guard let own = inspector.entry(at: path) else { return .missing }
        if own.kind == .symlink { return .symlink }
        guard own.kind == .directory else { return .notADirectory }
        guard inspector.realPath(path) == path else { return .symlinkedAncestor }
        guard let rootEntry = inspector.entry(at: root), rootEntry.device == own.device else { return .otherVolume }

        guard let manifest = candidate.category.projectManifest else { return nil }
        let parent = (path as NSString).deletingLastPathComponent
        guard inspector.entry(at: parent + "/" + manifest)?.kind == .file,
              let contents = try? inspector.entries(of: path),
              DiskCategoryRules.isBuildDirectory(candidate.category, contents: Set(contents.map(\.name)))
        else { return .noLongerMatches }
        if candidate.category == .rustTarget {
            for profile in contents where profile.kind == .directory {
                let lock = path + "/" + profile.name + "/.cargo-lock"
                if inspector.entry(at: lock)?.kind == .file, inspector.isLockHeld(lock) { return .buildRunning }
            }
        }
        return nil
    }

    /// Exactly where its category says: a fixed path, or a project directory outside tool-owned places.
    private func matchesCategoryPath(_ candidate: DiskCandidate) -> Bool {
        if let relative = candidate.category.fixedRelativePath {
            return candidate.path == root + "/" + relative
        }
        guard (candidate.path as NSString).lastPathComponent == candidate.category.projectDirectoryName else { return false }
        return !DiskCategoryRules.isToolOwned(candidate.path, root: root)
    }

    /// Absolute, no empty, `.` or `..` components, no trailing slash.
    static func isPlainAbsolute(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1, !path.hasSuffix("/") else { return false }
        return !path.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
            .contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }
}

struct LiveDeletionInspector: DeletionInspecting {
    private let reader = LiveDirectoryReader()

    func entry(at path: String) -> DirectoryEntry? { reader.entry(at: path) }
    func entries(of path: String) throws -> [DirectoryEntry] { try reader.entries(of: path) }

    func realPath(_ path: String) -> String? {
        guard let resolved = Darwin.realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// Try for the lock without waiting and let go at once. A cargo starting in that instant waits
    /// a moment ("Blocking waiting for file lock") — never longer than these two calls take.
    func isLockHeld(_ path: String) -> Bool {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return false
        }
        return errno == EWOULDBLOCK
    }
}
