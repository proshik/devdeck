import Foundation
import Darwin

/// The recovery state file — behind a protocol so the journal is tested in memory.
protocol RecoveryStoring {
    func read() -> Data?
    func write(_ data: Data)
}

/// Operation markers: one byte the previous process may have left set.
protocol RecoveryMarkerStoring {
    /// What the previous process left, then zero.
    func readAndReset() -> UInt8
    func write(_ mask: UInt8)
}

/// `recovery.json` in the data directory, 0600 like everything else DevDeck keeps.
final class FileRecoveryStorage: RecoveryStoring {
    private let url: URL
    init(url: URL) { self.url = url }

    func read() -> Data? { try? Data(contentsOf: url) }

    func write(_ data: Data) {
        do {
            try PrivateFile.makeDirectory(at: url.deletingLastPathComponent())
            try data.write(to: url, options: .atomic)
            PrivateFile.restrict(url)
        } catch {
            DiagnosticLog.shared.log("Recovery: could not save \(url.lastPathComponent) — \(error.localizedDescription)",
                                     level: .warn)
        }
    }
}

/// One byte at offset 0 of a file kept open for the process lifetime. `pwrite` without `fsync`:
/// the kernel's page cache outlives any death of the process (crash, SIGKILL, jetsam), and a power
/// loss is a new boot, which recovery ignores anyway. One syscall per marker change.
final class FileRecoveryMarkerStorage: RecoveryMarkerStoring {
    private let descriptor: Int32

    init?(url: URL) {
        try? PrivateFile.makeDirectory(at: url.deletingLastPathComponent())
        let fd = open(url.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            DiagnosticLog.shared.log("Recovery: markers unavailable — errno \(errno)", level: .warn)
            return nil
        }
        _ = fchmod(fd, 0o600)
        descriptor = fd
    }

    deinit { close(descriptor) }

    func readAndReset() -> UInt8 {
        var byte: UInt8 = 0
        let count = pread(descriptor, &byte, 1, 0)
        write(0)
        return count == 1 ? byte : 0
    }

    func write(_ mask: UInt8) {
        var byte = mask
        _ = pwrite(descriptor, &byte, 1, 0)
    }
}
