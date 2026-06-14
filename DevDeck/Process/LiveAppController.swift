import AppKit

/// Real GUI-application controller: listing (by memory), graceful quit, relaunch.
/// `@MainActor` — `NSWorkspace`/`NSRunningApplication` is main-affine. Not covered by unit tests.
///
/// Memory is the phys_footprint of the app's main process (`ProcessTree.physFootprint`); helpers
/// (e.g. Google Chrome Helper) do not appear in `NSWorkspace.runningApplications`, so this is
/// a lower bound — sufficient for relative ranking of "who uses the most memory".
@MainActor
final class LiveAppController: AppController {
    /// Stateless — can be created from any context (e.g. as a default argument).
    nonisolated init() {}

    func runningApps() -> [RunningApp] {
        NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil }
            .map { app in
                RunningApp(
                    bundleID: app.bundleIdentifier ?? "",
                    name: app.localizedName ?? app.bundleIdentifier ?? "—",
                    memoryBytes: ProcessTree.physFootprint(app.processIdentifier)
                )
            }
            .sorted { $0.memoryBytes > $1.memoryBytes }
    }

    func quit(_ bundleIDs: [String], timeout: TimeInterval) async -> [String] {
        let targets = Set(bundleIDs)
        // Only quit apps that are CURRENTLY running (otherwise we'd "close" something that
        // wasn't running and then incorrectly relaunch it).
        let initiallyRunning = Self.stillRunning(targets)

        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier.map(targets.contains) == true {
            app.terminate()   // gracefully, without force
        }

        // Wait for them to close, but no longer than timeout; exit on cancellation (no busy-spin).
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, !Self.stillRunning(initiallyRunning).isEmpty {
            if Task.isCancelled { break }
            do { try await Task.sleep(nanoseconds: 200_000_000) } catch { break }
        }

        let closed = initiallyRunning.subtracting(Self.stillRunning(initiallyRunning))
        return bundleIDs.filter { closed.contains($0) }   // only those that actually closed, in original order
    }

    func relaunch(_ bundleIDs: [String]) {
        for bundleID in bundleIDs {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { continue }
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { _, _ in }
        }
    }

    private static func stillRunning(_ targets: Set<String>) -> Set<String> {
        Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)).intersection(targets)
    }

}
