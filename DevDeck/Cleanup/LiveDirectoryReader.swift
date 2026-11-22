import Darwin
import Foundation

/// `opendir` + `fstatat(AT_SYMLINK_NOFOLLOW)` — every entry is the thing itself, a symlink never
/// its target. Plain POSIX on purpose: `FileManager`'s enumerator is several times slower on a
/// tree of millions of files and folds access errors into a log line instead of returning them.
struct LiveDirectoryReader: DirectoryReading {
    func entry(at path: String) -> DirectoryEntry? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        return Self.entry(name: (path as NSString).lastPathComponent, info)
    }

    func entries(of path: String, expecting: DirectoryEntry?) throws -> [DirectoryEntry] {
        let fd = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Self.error(errno) }
        if let expecting {
            // O_NOFOLLOW guards the last component only; an ancestor swapped for a link since the
            // parent was listed would land somewhere else — the inode says whether it did.
            var opened = stat()
            guard fstat(fd, &opened) == 0,
                  UInt64(bitPattern: Int64(opened.st_dev)) == expecting.device,
                  opened.st_ino == expecting.inode else {
                close(fd)
                throw DirectoryReadError.failed
            }
        }
        guard let dir = fdopendir(fd) else {
            let code = errno
            close(fd)
            throw Self.error(code)
        }
        defer { closedir(dir) }
        var out: [DirectoryEntry] = []
        while true {
            // A flat directory of a million entries must not hold a stop for its whole length.
            if out.count % 1_000 == 999, Task.isCancelled { throw DirectoryReadError.cancelled }
            errno = 0
            guard let raw = readdir(dir) else {
                // nil is both the end and an error; only errno tells them apart.
                if errno != 0 { throw Self.error(errno) }
                break
            }
            var buffer = raw.pointee.d_name
            let capacity = MemoryLayout.size(ofValue: buffer)
            let name = withUnsafePointer(to: &buffer) {
                $0.withMemoryRebound(to: CChar.self, capacity: capacity) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
                let code = errno
                // Vanished between readdir and stat — a temp file of a running build; skip it.
                if code == ENOENT { continue }
                // Names readable but not their entries: what this directory holds is unknown.
                throw Self.error(code)
            }
            out.append(Self.entry(name: name, info))
        }
        return out
    }

    private static func entry(name: String, _ info: stat) -> DirectoryEntry {
        let kind: DirectoryEntry.Kind
        switch info.st_mode & S_IFMT {
        case S_IFREG: kind = .file
        case S_IFDIR: kind = .directory
        case S_IFLNK: kind = .symlink
        default: kind = .other
        }
        return DirectoryEntry(name: name, kind: kind,
                              allocatedBytes: UInt64(max(0, info.st_blocks)) * 512,
                              device: UInt64(bitPattern: Int64(info.st_dev)),
                              inode: info.st_ino,
                              linkCount: UInt32(info.st_nlink),
                              modified: TimeInterval(info.st_mtimespec.tv_sec))
    }

    private static func error(_ code: Int32) -> DirectoryReadError {
        code == EACCES || code == EPERM ? .denied : .failed
    }
}
