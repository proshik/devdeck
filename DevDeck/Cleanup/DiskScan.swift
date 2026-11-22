import Foundation

// MARK: - Reading a directory (probe)

/// One entry of a directory as `lstat` sees it — a symlink is the link itself, never its target.
struct DirectoryEntry: Equatable, Sendable {
    enum Kind: Equatable, Sendable { case file, directory, symlink, other }

    let name: String
    let kind: Kind
    /// Blocks actually allocated on disk (`st_blocks × 512`) — a sparse VM disk counts what it holds.
    let allocatedBytes: UInt64
    let device: UInt64
    let inode: UInt64
    let linkCount: UInt32
    /// `st_mtime`, seconds since 1970.
    let modified: TimeInterval
}

enum DirectoryReadError: Error, Equatable, Sendable {
    /// EACCES / EPERM: the directory is there, this process may not list it.
    case denied
    /// Anything else (vanished mid-scan, not a directory any more, I/O error).
    case failed
    /// The task reading it was cancelled — a stop, not a read failure.
    case cancelled
}

/// Behind a protocol → the scanner is tested on an in-memory tree, never on the real home folder.
protocol DirectoryReading: Sendable {
    /// `lstat` of a single path; nil when it does not exist.
    func entry(at path: String) -> DirectoryEntry?
    /// The entries of a directory, `.` and `..` excluded. With `expecting`, the directory opened
    /// must be that one (same device and inode) — otherwise `.failed`.
    func entries(of path: String, expecting: DirectoryEntry?) throws -> [DirectoryEntry]
}

extension DirectoryReading {
    func entries(of path: String) throws -> [DirectoryEntry] { try entries(of: path, expecting: nil) }
}

// MARK: - Known categories

/// Data DevDeck recognises as rebuildable and may delete — every other folder is only measured.
enum DiskCategory: String, Codable, CaseIterable, Sendable {
    case rustTarget, nodeModules
    case libraryCaches, userCache, goModules, minikubeCache
    case xcodeDerivedData, npmCache, gradleCaches, cargoRegistry

    /// How a category goes away.
    enum Removal: Equatable, Sendable {
        /// `rm -rf` of the directory itself.
        case directory
        /// Everything inside; the directory stays (apps expect `~/Library/Caches` to exist).
        case contents
        /// `go clean -modcache`: module files are read-only, so a plain `rm -rf` fails on them.
        case goModCache
    }

    var removal: Removal {
        switch self {
        case .rustTarget, .nodeModules, .npmCache: return .directory
        case .goModules: return .goModCache
        case .libraryCaches, .userCache, .minikubeCache, .xcodeDerivedData, .gradleCaches, .cargoRegistry:
            return .contents
        }
    }

    /// Where a fixed category lives, relative to the home folder. nil for project categories,
    /// which are found by their neighbours wherever they sit.
    var fixedRelativePath: String? {
        switch self {
        case .rustTarget, .nodeModules: return nil
        case .libraryCaches: return "Library/Caches"
        case .userCache: return ".cache"
        case .goModules: return "go/pkg/mod"
        case .minikubeCache: return ".minikube/cache"
        case .xcodeDerivedData: return "Library/Developer/Xcode/DerivedData"
        case .npmCache: return ".npm/_cacache"
        case .gradleCaches: return ".gradle/caches"
        case .cargoRegistry: return ".cargo/registry"
        }
    }

    /// The project file that must sit next to a project category.
    var projectManifest: String? {
        switch self {
        case .rustTarget: return "Cargo.toml"
        case .nodeModules: return "package.json"
        default: return nil
        }
    }

    /// The directory name of a project category.
    var projectDirectoryName: String? {
        switch self {
        case .rustTarget: return "target"
        case .nodeModules: return "node_modules"
        default: return nil
        }
    }

    static let projectCategories: [DiskCategory] = [.rustTarget, .nodeModules]
    static let fixedCategories: [DiskCategory] = allCases.filter { $0.fixedRelativePath != nil }
}

// MARK: - Result

/// A directory in the saved tree. Only directories of `DiskScanner.treeFloor` and up are kept as
/// children; what the dropped ones held is the gap between `bytes` and the children's sum.
struct DiskNode: Codable, Equatable, Sendable {
    var name: String
    var bytes: UInt64
    var children: [DiskNode] = []
    /// Set on the directory a category was recognised at.
    var category: DiskCategory?

    var childrenBytes: UInt64 { children.reduce(0) { $0 + $1.bytes } }
    var otherBytes: UInt64 { bytes > childrenBytes ? bytes - childrenBytes : 0 }
}

/// Something the page offers to delete.
struct DiskCandidate: Codable, Equatable, Hashable, Sendable {
    let path: String
    let category: DiskCategory
    var bytes: UInt64
    /// The newest `mtime` anywhere inside — a build in progress keeps touching files deep down
    /// while the directory's own mtime stays put.
    let newestModification: TimeInterval
}

struct DiskScanResult: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version = DiskScanResult.currentVersion
    var scannedAt: Date
    /// The folder that was scanned — the home folder.
    var root: String
    var tree: DiskNode
    var fileCount: Int
    /// Candidates of `DiskScanner.candidateFloor` and up, biggest first.
    var candidates: [DiskCandidate]
    /// What the smaller candidates add up to — shown as one line, never offered for deletion.
    var smallCandidateCount: Int
    var smallCandidateBytes: UInt64
    /// Directories that refused to be listed. Capped; `unreadableCount` is the real number.
    var unreadable: [String]
    var unreadableCount: Int
    /// Protected folders that exist and were deliberately not entered (see `DiskScanner.protectedRelativePaths`).
    var skipped: [String]

    var isPartial: Bool { unreadableCount > 0 }

    /// A saved file is someone's to edit: a node smaller than its kept children is not a scan
    /// this code wrote, and is not shown.
    var isConsistent: Bool {
        func ok(_ node: DiskNode) -> Bool {
            var sum: UInt64 = 0
            for child in node.children {
                let (next, overflow) = sum.addingReportingOverflow(child.bytes)
                guard !overflow, ok(child) else { return false }
                sum = next
            }
            return sum <= node.bytes
        }
        guard ok(tree) else { return false }
        // Candidates are summed when ticked: their total must fit, and none outweighs the tree.
        var sum: UInt64 = 0
        for candidate in candidates {
            let (next, overflow) = sum.addingReportingOverflow(candidate.bytes)
            guard !overflow, candidate.bytes <= tree.bytes else { return false }
            sum = next
        }
        return true
    }

    /// Drop the candidates that are gone and take their bytes out of the tree, so the page stays
    /// truthful after a deletion without a rescan. `stillThere` is asked per removed path.
    mutating func forgetRemoved(_ paths: [String], stillThere: (String) -> Bool) {
        for path in paths where !stillThere(path) {
            guard let index = candidates.firstIndex(where: { $0.path == path }) else { continue }
            let candidate = candidates.remove(at: index)
            subtract(candidate.bytes, at: path)
        }
    }

    private mutating func subtract(_ bytes: UInt64, at path: String) {
        guard path.hasPrefix(root + "/") else { return }
        let components = path.dropFirst(root.count + 1).split(separator: "/").map(String.init)
        Self.subtract(bytes, along: components[...], in: &tree)
    }

    private static func subtract(_ bytes: UInt64, along components: ArraySlice<String>, in node: inout DiskNode) {
        node.bytes = node.bytes > bytes ? node.bytes - bytes : 0
        guard let first = components.first,
              let index = node.children.firstIndex(where: { $0.name == first }) else { return }
        if components.count == 1 && node.children[index].category?.removal != .contents {
            node.children.remove(at: index)
            return
        }
        subtract(bytes, along: components.dropFirst(), in: &node.children[index])
        if components.count == 1 { node.children[index].children = [] }
    }
}

/// How far a running scan got — written by the scan, read by the page a few times a second.
struct DiskScanProgress: Equatable, Sendable {
    var files = 0
    var bytes: UInt64 = 0
    /// The top-level folder being walked, relative to the root.
    var current: String?
}
