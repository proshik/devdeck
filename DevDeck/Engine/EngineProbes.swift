import AppKit
import Darwin

struct LiveProcessLiveness: ProcessLivenessChecking {
    /// `kill(pid, 0)` delivers nothing and only asks whether the pid exists. EPERM means it does
    /// but belongs to another user — still alive.
    func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

struct LivePathProbe: PathProbing {
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func contents(ofFile path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    func directoryEntries(at path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}

struct LiveAppPresence: AppPresenceProbing {
    func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
    func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

struct LiveUnixSocketProbe: UnixSocketProbing {
    /// A unix-socket `connect()` answers at once — success, ENOENT or ECONNREFUSED — so this
    /// never blocks. Nothing is written, so SIGPIPE can't happen.
    func canConnect(to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        return rc == 0
    }
}