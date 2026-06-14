import Foundation

/// An event surfaced to the user via a native macOS banner notification.
enum AppNotification: Equatable {
    case daemonStarted(name: String)                     // daemon came up
    case daemonStopped(name: String, code: Int32)        // daemon exited on its own ("crashed out")
    case daemonFailedToStart(name: String, code: Int32)  // daemon failed to start
    case daemonAdopted(name: String)                     // adopted from a previous session
    case commandFailed(name: String, code: Int32)        // regular command / chain step — error
}

/// Abstraction over native notifications (behind a protocol → `ProcessManager` orchestration
/// is tested with a fake, without real banners). `@MainActor`: the implementation touches
/// `UNUserNotificationCenter`, so all calls happen on the main thread.
@MainActor
protocol Notifier {
    func post(_ notification: AppNotification)
}

/// Default no-op stub: does nothing (for tests and builds without live notifications).
/// `nonisolated init` — so it can be used as a default argument in any context.
struct NoopNotifier: Notifier {
    nonisolated init() {}
    func post(_ notification: AppNotification) {}
}
