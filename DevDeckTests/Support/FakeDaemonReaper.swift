import Foundation
@testable import DevDeck

/// Fake reaper: programmable orphans per command and a kill log — no real processes.
@MainActor
final class FakeDaemonReaper: DaemonReaper {
    /// Command → PID of the found orphan. No key → orphan not found.
    var orphanByCommand: [String: Int32] = [:]
    private(set) var killed: [Int32] = []

    func findOrphan(matchingCommand command: String) -> Int32? {
        orphanByCommand[command]
    }

    func killTree(pid: Int32) { killed.append(pid) }
}
