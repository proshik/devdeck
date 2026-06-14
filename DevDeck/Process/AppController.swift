import Foundation

/// A running GUI application for the "Free Memory" picker.
struct RunningApp: Sendable, Equatable, Identifiable {
    var bundleID: String
    var name: String
    var memoryBytes: UInt64
    var id: String { bundleID }
}

/// Abstraction for working with GUI applications (behind a protocol so `ProcessManager`
/// orchestration can be tested with a fake, without actually quitting Chrome).
///
/// `@MainActor`: the implementation touches `NSWorkspace`/`NSRunningApplication` (main-affine),
/// so all methods must run on the main thread.
@MainActor
protocol AppController {
    /// Running GUI applications, sorted by memory usage (descending).
    func runningApps() -> [RunningApp]
    /// Gracefully quit applications and wait up to `timeout` for them to exit.
    /// Returns the bundleIDs of those that ACTUALLY closed.
    func quit(_ bundleIDs: [String], timeout: TimeInterval) async -> [String]
    /// Relaunch applications by bundleID.
    func relaunch(_ bundleIDs: [String])
}
