import AppKit
import ApplicationServices
import ServiceManagement
import UserNotifications

/// Reads and requests system permissions — behind a protocol so the page and its rules are
/// tested without TCC, Apple events or System Settings.
@MainActor
protocol PermissionProbing {
    func state(of kind: PermissionKind) async -> PermissionState
    /// Shows the system prompt. Callers decide whether a prompt is allowed (`PermissionsModel`).
    func request(_ kind: PermissionKind) async
    func openSettings(_ kind: PermissionKind)
}

@MainActor
final class LivePermissionProbe: PermissionProbing {
    private let pasteboard: any ClipboardPasteboard

    init(pasteboard: (any ClipboardPasteboard)? = nil) {
        self.pasteboard = pasteboard ?? SystemClipboardPasteboard()
    }

    func state(of kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .accessibility:
            return PermissionMapping.accessibility(trusted: AXIsProcessTrusted())
        case .clipboard:
            return PermissionMapping.clipboard(pasteboard.access)
        case .notifications:
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            return PermissionMapping.notifications(settings.authorizationStatus)
        case .automationGhostty:
            // Without Ghostty running the answer is procNotFound; skip the call (and its wait).
            guard GhosttyApp.isRunning() else { return .unknown }
            return PermissionMapping.automation(status: await Self.automationStatus(prompt: false))
        case .localNetwork:
            return LocalNetworkAccess.shared.state
        case .loginItem:
            return PermissionMapping.loginItem(SMAppService.mainApp.status)
        }
    }

    func request(_ kind: PermissionKind) async {
        switch kind {
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .clipboard:
            pasteboard.requestAccess()
        case .notifications:
            do {
                let granted = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                DiagnosticLog.shared.log("Notifications: \(granted ? "granted" : "denied by user") (permissions page)")
            } catch {
                DiagnosticLog.shared.log("Notifications: authorization error — \(error.localizedDescription)", level: .warn)
            }
        case .automationGhostty:
            guard GhosttyApp.isRunning() else { return }
            let status = await Self.automationStatus(prompt: true)
            DiagnosticLog.shared.log("Automation → Ghostty: status \(status) (permissions page)")
        case .localNetwork, .loginItem:
            break
        }
    }

    func openSettings(_ kind: PermissionKind) {
        if kind == .loginItem { SMAppService.openSystemSettingsLoginItems(); return }
        guard let url = Self.settingsURL(kind) else { return }
        NSWorkspace.shared.open(url)
    }

    static func settingsURL(_ kind: PermissionKind) -> URL? {
        let privacy = "x-apple.systempreferences:com.apple.preference.security"
        switch kind {
        case .accessibility: return URL(string: privacy + "?Privacy_Accessibility")
        case .automationGhostty: return URL(string: privacy + "?Privacy_Automation")
        case .localNetwork: return URL(string: privacy + "?Privacy_LocalNetwork")
        // Pasteboard privacy has no documented anchor: open Privacy & Security itself.
        case .clipboard: return URL(string: privacy)
        case .notifications:
            let id = Bundle.main.bundleIdentifier ?? "com.proshik.DevDeck"
            return URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)")
        case .loginItem: return nil
        }
    }

    /// `AEDeterminePermissionToAutomateTarget` may block (with a prompt, until the user answers),
    /// so it runs off the main actor.
    private nonisolated static func automationStatus(prompt: Bool) async -> OSStatus {
        await Task.detached(priority: .userInitiated) {
            var target = AEAddressDesc()
            let bundleID = Array(GhosttyApp.bundleID.utf8)
            let created = bundleID.withUnsafeBytes { bytes in
                AECreateDesc(DescType(typeApplicationBundleID), bytes.baseAddress, bytes.count, &target)
            }
            guard created == noErr else { return OSStatus(created) }
            defer { AEDisposeDesc(&target) }
            return AEDeterminePermissionToAutomateTarget(&target, AEEventClass(typeWildCard),
                                                         AEEventID(typeWildCard), prompt)
        }.value
    }
}
