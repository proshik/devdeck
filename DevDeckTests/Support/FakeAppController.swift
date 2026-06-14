import Foundation
@testable import DevDeck

/// Scriptable `AppController` for orchestration tests — no real application shutdown.
@MainActor
final class FakeAppController: AppController {
    var apps: [RunningApp] = []
    /// Bundle IDs that will "close" on quit; the rest "stay alive".
    var willQuit: Set<String> = []

    private(set) var quitCalls: [[String]] = []
    private(set) var relaunchCalls: [[String]] = []

    func runningApps() -> [RunningApp] { apps }

    func quit(_ bundleIDs: [String], timeout: TimeInterval) async -> [String] {
        quitCalls.append(bundleIDs)
        return bundleIDs.filter { willQuit.contains($0) }
    }

    func relaunch(_ bundleIDs: [String]) {
        relaunchCalls.append(bundleIDs)
    }
}
