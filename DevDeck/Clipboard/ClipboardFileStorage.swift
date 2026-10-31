import Foundation
import Darwin

/// History is the user's only copy. Create private temporary files BEFORE writing bytes,
/// then rename atomically; a failed transaction leaves the previous file intact.
struct ClipboardFileStorage: ClipboardHistoryStorage {
    let directory: URL
    var file: URL { directory.appendingPathComponent("history.json") }
    init(directory: URL = AppRuntime.supportDirectory.appendingPathComponent("Clipboard", isDirectory: true)) {
        self.directory = directory
    }
    private func protectDirectory() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              chmod(directory.path, 0o700) == 0 else { throw ClipboardHistoryError.writeFailed }
    }
    func read() throws -> Data? {
        try protectDirectory()
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW)
        if descriptor < 0 {
            if errno == ENOENT { return nil }
            throw ClipboardHistoryError.damaged
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size <= 101 * 1_024 * 1_024, fchmod(descriptor, 0o600) == 0 else {
            throw ClipboardHistoryError.damaged
        }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 { if errno == EINTR { continue }; throw ClipboardHistoryError.damaged }
            if count == 0 { return data }
            data.append(contentsOf: buffer.prefix(count))
            guard data.count <= 101 * 1_024 * 1_024 else { throw ClipboardHistoryError.damaged }
        }
    }
    func write(_ data: Data) throws {
        try protectDirectory()
        let temporary = directory.appendingPathComponent(".history-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ClipboardHistoryError.writeFailed }
        defer { close(descriptor); unlink(temporary.path) }
        guard fchmod(descriptor, 0o600) == 0 else { throw ClipboardHistoryError.writeFailed }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw ClipboardHistoryError.writeFailed }
                offset += count
            }
        }
        guard fsync(descriptor) == 0, rename(temporary.path, file.path) == 0 else {
            throw ClipboardHistoryError.writeFailed
        }
    }
}
