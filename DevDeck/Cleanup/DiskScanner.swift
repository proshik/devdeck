import Foundation

/// Walks the home folder and measures it: what every big directory holds, which of them are known
/// rebuildable categories, and what could not be read.
///
/// The rules are the point of the type, so they are spelled out:
/// - a symlink is counted as the link itself and never followed;
/// - a directory on another device (a mounted volume, a firmlink elsewhere) is not entered;
/// - sizes are allocated blocks, so a sparse VM disk counts what it actually holds;
/// - a file with several hard links is counted once, at its first sighting;
/// - a directory that refuses to be listed is recorded as unreadable, never prompted for;
/// - the folders macOS guards with a consent prompt (`protectedRelativePaths`) are not entered at all.
///
/// Blocking and long (minutes on a full disk): run it off the main actor. `isCancelled` is asked
/// once per directory.
struct DiskScanner {
    /// Folders where entering would make macOS show "DevDeck would like to access…" — the user
    /// chose to leave them out rather than ask (design §8.1). Relative to the root.
    static let protectedRelativePaths: [String] = [
        "Desktop", "Documents", "Downloads",
        "Library/Mobile Documents", "Library/Containers", "Library/Group Containers",
    ]

    /// Directories below this are folded into their parent's "other" in the saved tree.
    static let treeFloor: UInt64 = 100 * 1_048_576
    /// Candidates below this are summed into one line instead of being offered one by one.
    static let candidateFloor: UInt64 = 100 * 1_048_576
    /// How many unreadable paths the result keeps by name.
    static let unreadableKept = 200
    /// How many entries pass between two progress reports.
    static let progressEvery = 2_000

    let reader: any DirectoryReading
    let root: String

    init(reader: any DirectoryReading, root: String) {
        self.reader = reader
        self.root = root.count > 1 && root.hasSuffix("/") ? String(root.dropLast()) : root
    }

    struct Cancelled: Error {}

    func scan(now: Date = Date(),
              isCancelled: @escaping () -> Bool = { false },
              progress: @escaping (DiskScanProgress) -> Void = { _ in }) throws -> DiskScanResult {
        guard let rootEntry = reader.entry(at: root), rootEntry.kind == .directory else {
            throw DirectoryReadError.failed
        }
        var walk = Walk(reader: reader, root: root, device: rootEntry.device,
                        isCancelled: isCancelled, progress: progress)
        // APFS is case-insensitive by default: `documents` is the same folder as `Documents`.
        walk.protected = Set(Self.protectedRelativePaths.map { (root + "/" + $0).lowercased() })
        var tree = try walk.directory(at: root, name: (root as NSString).lastPathComponent,
                                      own: rootEntry, context: .free)
        tree.name = root
        let big = walk.candidates.filter { $0.bytes >= Self.candidateFloor }.sorted { $0.bytes > $1.bytes }
        let small = walk.candidates.filter { $0.bytes < Self.candidateFloor }
        return DiskScanResult(scannedAt: now, root: root, tree: tree, fileCount: walk.progressState.files,
                              candidates: big,
                              smallCandidateCount: small.count,
                              smallCandidateBytes: small.reduce(0) { $0 + $1.bytes },
                              unreadable: walk.unreadable, unreadableCount: walk.unreadableCount,
                              skipped: walk.skipped.sorted())
    }

    /// Where a directory sits relative to the categories.
    enum Context: Equatable {
        /// Projects may be recognised here.
        case free
        /// Inside `~/Library` or a top-level dot-folder: tools keep their own `node_modules` and
        /// `target` there (editor extensions, plugins, `~/.cargo/git`), and those are not rebuilt by
        /// an `install` — only the fixed categories are recognised.
        case toolOwned
        /// Inside a recognised category: measured, nothing nested is offered separately.
        case inCategory
    }

    private struct InodeKey: Hashable {
        let device: UInt64
        let inode: UInt64
    }

    private struct Walk {
        let reader: any DirectoryReading
        let root: String
        let device: UInt64
        let isCancelled: () -> Bool
        let progress: (DiskScanProgress) -> Void
        var protected: Set<String> = []

        var progressState = DiskScanProgress()
        var sinceReport = 0
        var seenLinks = Set<InodeKey>()
        var candidates: [DiskCandidate] = []
        var unreadable: [String] = []
        var unreadableCount = 0
        var skipped: [String] = []
        /// The newest mtime seen inside the directory being finished — per frame of the recursion.
        var newest: TimeInterval = 0
        /// The entry names of the directory just finished — what a project category is confirmed by.
        var lastNames: Set<String> = []

        mutating func directory(at path: String, name: String, own: DirectoryEntry,
                                context: Context) throws -> DiskNode {
            if isCancelled() { throw Cancelled() }
            var node = DiskNode(name: name, bytes: own.allocatedBytes)
            var newestHere = own.modified
            let entries: [DirectoryEntry]
            do {
                // The directory must still be the one its parent listed — not a link swapped in.
                entries = try reader.entries(of: path, expecting: own)
            } catch DirectoryReadError.cancelled {
                throw Cancelled()
            } catch {
                unreadableCount += 1
                if unreadable.count < DiskScanner.unreadableKept { unreadable.append(path) }
                newest = newestHere
                lastNames = []
                return node
            }

            let names = Set(entries.map(\.name))
            let fileNames = Set(entries.filter { $0.kind == .file }.map(\.name))
            for (index, entry) in entries.enumerated() {
                // A flat directory of a million files must not hold a stop for its whole length.
                if index % 1_000 == 999, isCancelled() { throw Cancelled() }
                let childPath = path + "/" + entry.name
                switch entry.kind {
                case .directory:
                    if protected.contains(childPath.lowercased()) {
                        skipped.append(childPath)
                        continue
                    }
                    // Another volume mounted or firmlinked inside home is not home's disk.
                    guard entry.device == device else { continue }
                    if path == root { progressState.current = entry.name; report(force: true) }
                    let category = recognise(childPath, name: entry.name, siblingFiles: fileNames, context: context)
                    let childContext: Context
                    if category != nil { childContext = .inCategory }
                    else if context == .free && path == root
                                && DiskCategoryRules.isToolOwnedTopLevel(entry.name) { childContext = .toolOwned }
                    else { childContext = context }
                    var child = try directory(at: childPath, name: entry.name, own: entry, context: childContext)
                    newestHere = max(newestHere, newest)
                    if let category, confirms(category, contents: lastNames) {
                        child.category = category
                        candidates.append(DiskCandidate(path: childPath, category: category, bytes: child.bytes,
                                                        newestModification: newest))
                    }
                    node.bytes += child.bytes
                    if child.bytes >= DiskScanner.treeFloor { node.children.append(child) }
                default:
                    newestHere = max(newestHere, entry.modified)
                    count(entry, into: &node)
                }
            }
            node.children.sort { $0.bytes > $1.bytes }
            newest = newestHere
            lastNames = names
            return node
        }

        /// A file, symlink or other non-directory: its blocks, once per inode.
        mutating func count(_ entry: DirectoryEntry, into node: inout DiskNode) {
            progressState.files += 1
            if entry.linkCount > 1 && entry.kind == .file {
                guard seenLinks.insert(InodeKey(device: entry.device, inode: entry.inode)).inserted else {
                    report(force: false)
                    return
                }
            }
            node.bytes += entry.allocatedBytes
            progressState.bytes += entry.allocatedBytes
            report(force: false)
        }

        mutating func report(force: Bool) {
            sinceReport += 1
            guard force || sinceReport >= DiskScanner.progressEvery else { return }
            sinceReport = 0
            progress(progressState)
        }

        /// The category a directory is, judged by its path and its parent's files.
        func recognise(_ path: String, name: String, siblingFiles: Set<String>, context: Context) -> DiskCategory? {
            guard context != .inCategory else { return nil }
            if let fixed = DiskCategory.fixedCategories.first(where: { root + "/" + $0.fixedRelativePath! == path }) {
                return fixed
            }
            guard context == .free else { return nil }
            return DiskCategory.projectCategories.first {
                $0.projectDirectoryName == name && siblingFiles.contains($0.projectManifest!)
            }
        }

        /// A project category is confirmed only once its own listing is known: a `target` holding a
        /// `Cargo.toml` or `.git` is a project of its own, not a build directory.
        func confirms(_ category: DiskCategory, contents: Set<String>) -> Bool {
            guard DiskCategory.projectCategories.contains(category) else { return true }
            return DiskCategoryRules.isBuildDirectory(category, contents: contents)
        }
    }
}

/// The category checks the scanner and the deletion guard share — one rule, two callers.
enum DiskCategoryRules {
    /// What may not sit directly inside a project category: it would make it a project root.
    /// Names are compared case-insensitively: on the default (case-insensitive) APFS a `.GIT`
    /// is the same `.git` to git and to the shell's `[ -e ]`.
    static func isBuildDirectory(_ category: DiskCategory, contents: Set<String>) -> Bool {
        let names = Set(contents.map { $0.lowercased() })
        if names.contains(".git") { return false }
        if category == .rustTarget && names.contains("cargo.toml") { return false }
        return true
    }

    /// Inside `~/Library` or a top-level dot-folder of `root`.
    static func isToolOwned(_ path: String, root: String) -> Bool {
        guard path.hasPrefix(root + "/") else { return false }
        let first = path.dropFirst(root.count + 1).split(separator: "/").first ?? ""
        return isToolOwnedTopLevel(String(first))
    }

    /// A top-level folder tools keep their own data in. Any case: `library` is `Library` on APFS.
    static func isToolOwnedTopLevel(_ name: String) -> Bool {
        name.hasPrefix(".") || name.lowercased() == "library"
    }
}
