import Foundation
@testable import DevDeck

/// An in-memory file tree for the scanner — no real paths are listed or measured.
///
/// Built path by path: `dir("/h/work")`, `file("/h/work/a", bytes: 10)`. Parents are created on the
/// way, all on device 1 unless `device:` says otherwise.
final class FakeDirectoryReader: DirectoryReading, @unchecked Sendable {
    private let lock = NSLock()
    private var nodes: [String: DirectoryEntry] = [:]
    private var children: [String: [String]] = [:]
    private var denied: Set<String> = []
    private var nextInode: UInt64 = 100
    private var _listed: [String] = []

    /// Every directory the scanner asked to list, in order.
    var listed: [String] { lock.lock(); defer { lock.unlock() }; return _listed }

    init(root: String) { dir(root) }

    @discardableResult
    func dir(_ path: String, device: UInt64 = 1, modified: TimeInterval = 0) -> Self {
        add(path, kind: .directory, bytes: 0, device: device, inode: nil, links: 1, modified: modified)
        return self
    }

    @discardableResult
    func file(_ path: String, bytes: UInt64, modified: TimeInterval = 0, inode: UInt64? = nil, links: UInt32 = 1) -> Self {
        add(path, kind: .file, bytes: bytes, device: 1, inode: inode, links: links, modified: modified)
        return self
    }

    @discardableResult
    func symlink(_ path: String) -> Self {
        add(path, kind: .symlink, bytes: 0, device: 1, inode: nil, links: 1, modified: 0)
        return self
    }

    func deny(_ path: String) { lock.lock(); denied.insert(path); lock.unlock() }

    private func add(_ path: String, kind: DirectoryEntry.Kind, bytes: UInt64, device: UInt64,
                     inode: UInt64?, links: UInt32, modified: TimeInterval) {
        let parent = (path as NSString).deletingLastPathComponent
        if parent != path, entry(at: parent) == nil {
            add(parent, kind: .directory, bytes: 0, device: 1, inode: nil, links: 1, modified: 0)
        }
        lock.lock(); defer { lock.unlock() }
        nextInode += 1
        let name = (path as NSString).lastPathComponent
        if nodes[path] == nil { children[parent, default: []].append(name) }
        nodes[path] = DirectoryEntry(name: name, kind: kind, allocatedBytes: bytes, device: device,
                                     inode: inode ?? nextInode, linkCount: links, modified: modified)
    }

    func entry(at path: String) -> DirectoryEntry? {
        lock.lock(); defer { lock.unlock() }
        return nodes[path]
    }

    func entries(of path: String) throws -> [DirectoryEntry] {
        lock.lock(); defer { lock.unlock() }
        _listed.append(path)
        if denied.contains(path) { throw DirectoryReadError.denied }
        guard nodes[path]?.kind == .directory else { throw DirectoryReadError.failed }
        return (children[path] ?? []).compactMap { nodes[path + "/" + $0] }
    }
}

/// The fake tree as the deletion guard sees it: paths resolve to themselves unless told otherwise,
/// and no lock is held unless told so.
final class FakeDeletionInspector: DeletionInspecting, @unchecked Sendable {
    let fs: FakeDirectoryReader
    var resolved: [String: String] = [:]
    var heldLocks: Set<String> = []

    init(_ fs: FakeDirectoryReader) { self.fs = fs }

    func entry(at path: String) -> DirectoryEntry? { fs.entry(at: path) }
    func entries(of path: String) throws -> [DirectoryEntry] { try fs.entries(of: path) }
    func realPath(_ path: String) -> String? { fs.entry(at: path) == nil ? nil : (resolved[path] ?? path) }
    func isLockHeld(_ path: String) -> Bool { heldLocks.contains(path) }
}
