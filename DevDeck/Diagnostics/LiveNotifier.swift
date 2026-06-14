import Foundation
import UserNotifications

/// Native macOS notifications via `UserNotifications` — local banners, no network and no special
/// entitlements; works for a menu bar (`LSUIElement`) app.
/// A daemon/command failure makes a sound; a daemon start is silent.
@MainActor
final class LiveNotifier: Notifier {
    private var authorizationRequested = false

    nonisolated init() {}

    /// Request permission once (from `AppDelegate` at startup). Idempotent.
    func requestAuthorization() {
        guard !authorizationRequested else { return }
        authorizationRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                DiagnosticLog.shared.log("Notifications: authorization error — \(error.localizedDescription)", level: .warn)
            } else {
                DiagnosticLog.shared.log("Notifications: \(granted ? "granted" : "denied by user")")
            }
        }
    }

    func post(_ notification: AppNotification) {
        let content = UNMutableNotificationContent()
        switch notification {
        case .daemonStarted(let name):
            content.title = L10n.notifDaemonStarted
            content.body = name
            // silent — no sound
        case .daemonAdopted(let name):
            content.title = L10n.notifDaemonAdopted
            content.body = name
            // silent — informational
        case .daemonStopped(let name, let code):
            content.title = L10n.notifDaemonStopped
            content.body = code == 0 ? name : L10n.notifNameCode(name, code)
            content.sound = .default
        case .daemonFailedToStart(let name, let code):
            content.title = L10n.notifDaemonFailedToStart
            content.body = L10n.notifNameCode(name, code)
            content.sound = .default
        case .commandFailed(let name, let code):
            content.title = L10n.notifCommandFailed
            content.body = L10n.notifNameCode(name, code)
            content.sound = .default
        }

        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                DiagnosticLog.shared.log("Notification not delivered: \(error.localizedDescription)", level: .warn)
            }
        }
    }
}
