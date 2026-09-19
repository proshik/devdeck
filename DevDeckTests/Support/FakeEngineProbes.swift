import Foundation
@testable import DevDeck

final class FakePathProbe: PathProbing, @unchecked Sendable {
    var existing: Set<String> = []
    var files: [String: String] = [:]
    var directories: [String: [String]] = [:]
    func exists(_ path: String) -> Bool { existing.contains(path) || files[path] != nil || directories[path] != nil }
    func contents(ofFile path: String) -> String? { files[path] }
    func directoryEntries(at path: String) -> [String] { directories[path] ?? [] }
}

final class FakeLiveness: ProcessLivenessChecking, @unchecked Sendable {
    var alive: Set<Int32> = []
    func isAlive(pid: Int32) -> Bool { alive.contains(pid) }
}

final class FakeAppPresence: AppPresenceProbing, @unchecked Sendable {
    var running: Set<String> = []
    var installed: Set<String> = []
    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
}

final class FakeSocketProbe: UnixSocketProbing, @unchecked Sendable {
    var connectable: Set<String> = []
    private(set) var attempts: [String] = []
    func canConnect(to path: String) -> Bool { attempts.append(path); return connectable.contains(path) }
}

/// An engine with fixed answers — for the selector and the model.
final class FakeEngine: ContainerEngine, @unchecked Sendable {
    let kind: ContainerEngineKind
    let displayName: String
    var installed: Bool
    var running: Bool
    init(_ kind: ContainerEngineKind, installed: Bool = true, running: Bool = false) {
        self.kind = kind
        self.displayName = kind == .colima ? "colima" : "Docker Desktop"
        self.installed = installed
        self.running = running
    }
    func isInstalled() -> Bool { installed }
    func isRunning() -> Bool { running }
}