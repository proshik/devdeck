import Foundation
import ServiceManagement
import UserNotifications

/// The system permissions DevDeck actually uses (REC-01). Screen Recording and Full Disk Access
/// are not among them, so the page does not show them.
enum PermissionKind: String, CaseIterable, Identifiable, Sendable {
    case accessibility, clipboard, notifications, automationGhostty, localNetwork, loginItem
    var id: String { rawValue }

    /// The features that need this permission, in display order.
    var features: [PermissionFeature] {
        switch self {
        case .accessibility: [.brightnessKeys, .clipboardPaste]
        case .clipboard: [.clipboardHistory]
        case .notifications: [.commandNotifications]
        case .automationGhostty: [.agentTabsRestore, .terminalCommands]
        case .localNetwork: [.proxyDiscovery, .proxyShare]
        case .loginItem: [.launchAtLogin]
        }
    }

    /// Local network has no public request API (browsing itself prompts), and the login item is
    /// a switch in General settings rather than a prompt.
    var hasPrompt: Bool {
        switch self {
        case .accessibility, .clipboard, .notifications, .automationGhostty: true
        case .localNetwork, .loginItem: false
        }
    }
}

/// What the system reports. Not every permission can tell every state apart: Accessibility has no
/// "denied" distinct from "not yet asked", local network has no query API at all.
enum PermissionState: Equatable, Sendable {
    case granted
    case denied
    case notDetermined
    /// Accessibility is not granted — asked or not, macOS does not say.
    case missing
    /// Pasteboard privacy: macOS asks each time another app's content is read.
    case askEachTime
    /// Login item registered but waiting for approval in System Settings.
    case needsApproval
    /// Login item not registered.
    case off
    case unknown

    /// Whether a system prompt can still change anything.
    var isPromptable: Bool {
        switch self {
        case .notDetermined, .missing, .askEachTime: true
        default: false
        }
    }
}

enum PermissionFeature: CaseIterable, Equatable, Hashable, Sendable {
    case brightnessKeys, clipboardPaste, clipboardHistory, commandNotifications, agentTabsRestore,
         terminalCommands, proxyDiscovery, proxyShare, launchAtLogin
}

/// Which features are switched on — a system prompt is offered only for those.
struct PermissionFeatureFlags: Equatable, Sendable {
    var enabled: Set<PermissionFeature> = [.commandNotifications]

    init() {}

    init(config: Config, launchAtLogin: Bool) {
        let settings = config.settings
        var enabled: Set<PermissionFeature> = [.commandNotifications]   // commands always notify
        if settings.displays.keyboardEnabled { enabled.insert(.brightnessKeys) }
        if settings.clipboard.enabled { enabled.insert(.clipboardHistory) }
        if settings.clipboard.pasteEnabled { enabled.insert(.clipboardPaste) }
        if settings.claudeTabsRestore { enabled.insert(.agentTabsRestore) }
        if config.commands.contains(where: \.openInTerminal) || config.chains.contains(where: \.openInTerminal) {
            enabled.insert(.terminalCommands)
        }
        if settings.proxyDiscoveryEnabled { enabled.insert(.proxyDiscovery) }
        if settings.proxyShareEnabled { enabled.insert(.proxyShare) }
        if launchAtLogin { enabled.insert(.launchAtLogin) }
        self.enabled = enabled
    }
}

/// Pure translations of the system answers — tested without the system.
enum PermissionMapping {
    static func accessibility(trusted: Bool) -> PermissionState { trusted ? .granted : .missing }

    /// `AEDeterminePermissionToAutomateTarget` result.
    static func automation(status: OSStatus) -> PermissionState {
        switch status {
        case 0: .granted
        case -1743: .denied          // errAEEventNotPermitted
        case -1744: .notDetermined   // errAEEventWouldRequireUserConsent
        default: .unknown            // procNotFound (-600): Ghostty is not running, or not installed
        }
    }

    static func notifications(_ status: UNAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        case .notDetermined: .notDetermined
        @unknown default: .unknown
        }
    }

    static func loginItem(_ status: SMAppService.Status) -> PermissionState {
        switch status {
        case .enabled: .granted
        case .requiresApproval: .needsApproval
        case .notRegistered: .off
        case .notFound: .unknown
        @unknown default: .unknown
        }
    }

    static func clipboard(_ access: ClipboardAccess) -> PermissionState {
        switch access {
        case .allowed: .granted
        case .denied: .denied
        case .needsPermission: .askEachTime
        }
    }
}

/// Local network permission as the Bonjour browser saw it. There is no API to query it: a browser
/// that reaches `ready` has it, one that waits with `PolicyDenied` does not; before the proxy
/// features ever browsed, nothing is known.
@MainActor
final class LocalNetworkAccess {
    static let shared = LocalNetworkAccess()
    private(set) var state: PermissionState = .unknown

    func browserBecameReady() { state = .granted }

    /// Only `kDNSServiceErr_PolicyDenied` speaks about the permission; other waits (no network)
    /// leave the last known answer.
    func browserWaiting(policyDenied: Bool) {
        if policyDenied { state = .denied }
    }
}
