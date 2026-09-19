import Foundation

/// The container engines DevDeck knows how to recognise.
enum ContainerEngineKind: String, Codable, CaseIterable, Sendable {
    case colima, dockerDesktop
}

/// A local container engine: its name and whether it is there and up.
///
/// `isRunning()` is polled every 2 s from the tray timer, so implementations must not spawn a
/// process — a file read, a `kill(pid, 0)` or a unix-socket `connect()` at most.
protocol ContainerEngine: Sendable {
    var kind: ContainerEngineKind { get }
    /// As shown in the UI: "colima", "Docker Desktop".
    var displayName: String { get }
    func isInstalled() -> Bool
    func isRunning() -> Bool
}

// MARK: - Probes (behind protocols → engines are tested with fakes, no real paths or processes)

protocol ProcessLivenessChecking: Sendable {
    func isAlive(pid: Int32) -> Bool
}

protocol PathProbing: Sendable {
    func exists(_ path: String) -> Bool
    func contents(ofFile path: String) -> String?
    /// Names (not paths) of the entries of a directory; empty when it doesn't exist.
    func directoryEntries(at path: String) -> [String]
}

protocol AppPresenceProbing: Sendable {
    func isRunning(bundleID: String) -> Bool
    func isInstalled(bundleID: String) -> Bool
}

protocol UnixSocketProbing: Sendable {
    func canConnect(to path: String) -> Bool
}