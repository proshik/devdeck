import XCTest
import AppKit
import SwiftUI
import ServiceManagement
import UserNotifications
@testable import DevDeck

@MainActor
final class PermissionsTests: XCTestCase {

    // MARK: mapping of the system answers

    func testAppleEventStatusMapsToState() {
        XCTAssertEqual(PermissionMapping.automation(status: 0), .granted)
        XCTAssertEqual(PermissionMapping.automation(status: -1743), .denied)          // errAEEventNotPermitted
        XCTAssertEqual(PermissionMapping.automation(status: -1744), .notDetermined)   // would require consent
        XCTAssertEqual(PermissionMapping.automation(status: -600), .unknown)          // procNotFound: Ghostty not running
        XCTAssertEqual(PermissionMapping.automation(status: -1), .unknown)
    }

    func testNotificationStatusMapsToState() {
        XCTAssertEqual(PermissionMapping.notifications(.authorized), .granted)
        XCTAssertEqual(PermissionMapping.notifications(.provisional), .granted)
        XCTAssertEqual(PermissionMapping.notifications(.denied), .denied)
        XCTAssertEqual(PermissionMapping.notifications(.notDetermined), .notDetermined)
    }

    func testLoginItemStatusMapsToState() {
        XCTAssertEqual(PermissionMapping.loginItem(.enabled), .granted)
        XCTAssertEqual(PermissionMapping.loginItem(.requiresApproval), .needsApproval)
        XCTAssertEqual(PermissionMapping.loginItem(.notRegistered), .off)
        XCTAssertEqual(PermissionMapping.loginItem(.notFound), .unknown)
    }

    func testClipboardAccessMapsToState() {
        XCTAssertEqual(PermissionMapping.clipboard(.allowed), .granted)
        XCTAssertEqual(PermissionMapping.clipboard(.denied), .denied)
        XCTAssertEqual(PermissionMapping.clipboard(.needsPermission), .askEachTime)
    }

    func testAccessibilityHasNoDistinctDeniedState() {
        XCTAssertEqual(PermissionMapping.accessibility(trusted: true), .granted)
        XCTAssertEqual(PermissionMapping.accessibility(trusted: false), .missing)
    }

    func testLocalNetworkStateComesFromTheBrowser() {
        let tracker = LocalNetworkAccess()
        XCTAssertEqual(tracker.state, .unknown)
        tracker.browserBecameReady()
        XCTAssertEqual(tracker.state, .granted)
        tracker.browserWaiting(policyDenied: true)
        XCTAssertEqual(tracker.state, .denied)
        tracker.browserWaiting(policyDenied: false)   // any other wait says nothing about permission
        XCTAssertEqual(tracker.state, .denied)
        tracker.browserBecameReady()
        XCTAssertEqual(tracker.state, .granted)
    }

    // MARK: which features need a permission

    func testFeatureFlagsReadTheConfig() {
        var config = Config.empty
        XCTAssertEqual(PermissionFeatureFlags(config: config, launchAtLogin: false), PermissionFeatureFlags())
        config.settings.displays.keyboardEnabled = true
        config.settings.clipboard.enabled = true
        config.settings.clipboard.pasteEnabled = true
        config.settings.claudeTabsRestore = true
        config.settings.proxyDiscoveryEnabled = true
        config.commands = [Command(id: UUID(), name: "t", command: "true", openInTerminal: true)]
        let flags = PermissionFeatureFlags(config: config, launchAtLogin: true)
        XCTAssertEqual(flags.enabled, Set(PermissionFeature.allCases).subtracting([.proxyShare]))
    }

    func testTerminalChainCountsAsTerminalFeature() {
        var config = Config.empty
        config.chains = [Chain(id: UUID(), name: "c", commandIDs: [], openInTerminal: true)]
        XCTAssertTrue(PermissionFeatureFlags(config: config, launchAtLogin: false).enabled.contains(.terminalCommands))
    }

    func testEveryPermissionNamesItsFeatures() {
        XCTAssertEqual(PermissionKind.accessibility.features, [.brightnessKeys, .clipboardPaste])
        XCTAssertEqual(PermissionKind.clipboard.features, [.clipboardHistory])
        XCTAssertEqual(PermissionKind.notifications.features, [.commandNotifications])
        XCTAssertEqual(PermissionKind.automationGhostty.features, [.agentTabsRestore, .terminalCommands])
        XCTAssertEqual(PermissionKind.localNetwork.features, [.proxyDiscovery, .proxyShare])
        XCTAssertEqual(PermissionKind.loginItem.features, [.launchAtLogin])
    }

    // MARK: model

    private func model(_ probe: FakePermissionProbe, flags: PermissionFeatureFlags = .init()) -> PermissionsModel {
        PermissionsModel(probe: probe, flags: { flags })
    }

    func testRefreshReadsEveryPermission() async {
        let probe = FakePermissionProbe()
        probe.states = [.accessibility: .granted, .clipboard: .askEachTime, .notifications: .denied,
                        .automationGhostty: .notDetermined, .localNetwork: .unknown, .loginItem: .off]
        let permissions = model(probe)
        await permissions.refresh()
        XCTAssertEqual(permissions.rows.map(\.kind), PermissionKind.allCases)
        XCTAssertEqual(permissions.rows.map(\.state), [.granted, .askEachTime, .denied, .notDetermined, .unknown, .off])
    }

    func testNoPromptWhileNoFeatureNeedsThePermission() async {
        let probe = FakePermissionProbe()
        probe.states = [.accessibility: .missing, .automationGhostty: .notDetermined, .clipboard: .askEachTime]
        let permissions = model(probe)
        await permissions.refresh()
        for kind in [PermissionKind.accessibility, .automationGhostty, .clipboard] {
            XCTAssertFalse(permissions.row(kind).canRequest, "\(kind) must not prompt with its features off")
            await permissions.request(kind)
        }
        XCTAssertEqual(probe.requested, [])
    }

    func testPromptOnceTheFeatureIsOnAndRefreshAfterTheAnswer() async {
        let probe = FakePermissionProbe()
        probe.states = [.accessibility: .missing]
        probe.answers = [.accessibility: .granted]
        var flags = PermissionFeatureFlags()
        flags.enabled = [.brightnessKeys]
        let permissions = model(probe, flags: flags)
        await permissions.refresh()
        XCTAssertTrue(permissions.row(.accessibility).canRequest)
        await permissions.request(.accessibility)
        XCTAssertEqual(probe.requested, [.accessibility])
        XCTAssertEqual(permissions.row(.accessibility).state, .granted)
        XCTAssertFalse(permissions.row(.accessibility).canRequest, "a granted permission offers no prompt")
    }

    func testNotificationsCanBeRequestedUntilDecided() async {
        let probe = FakePermissionProbe()
        probe.states = [.notifications: .notDetermined]
        let permissions = model(probe)
        await permissions.refresh()
        XCTAssertTrue(permissions.row(.notifications).canRequest, "command notifications are always on")
        probe.states = [.notifications: .denied]
        await permissions.refresh()
        XCTAssertFalse(permissions.row(.notifications).canRequest, "macOS asks only once; denied goes to Settings")
    }

    func testDeniedPermissionsAreNotPromptedAgain() async {
        let probe = FakePermissionProbe()
        probe.states = [.automationGhostty: .denied, .clipboard: .denied]
        var flags = PermissionFeatureFlags()
        flags.enabled = [.agentTabsRestore, .clipboardHistory]
        let permissions = model(probe, flags: flags)
        await permissions.refresh()
        XCTAssertFalse(permissions.row(.automationGhostty).canRequest)
        XCTAssertFalse(permissions.row(.clipboard).canRequest)
    }

    func testLocalNetworkAndLoginItemHaveNoPrompt() async {
        let probe = FakePermissionProbe()
        probe.states = [.localNetwork: .unknown, .loginItem: .off]
        var flags = PermissionFeatureFlags()
        flags.enabled = Set(PermissionFeature.allCases)
        let permissions = model(probe, flags: flags)
        await permissions.refresh()
        XCTAssertFalse(permissions.row(.localNetwork).canRequest)
        XCTAssertFalse(permissions.row(.loginItem).canRequest)
    }

    func testRowsListEnabledFeatures() async {
        let probe = FakePermissionProbe()
        var flags = PermissionFeatureFlags()
        flags.enabled = [.clipboardPaste]
        let permissions = model(probe, flags: flags)
        await permissions.refresh()
        let row = permissions.row(.accessibility)
        XCTAssertEqual(row.features.map(\.feature), [.brightnessKeys, .clipboardPaste])
        XCTAssertEqual(row.features.map(\.isEnabled), [false, true])
    }

    func testOpenSettingsGoesThroughTheProbe() async {
        let probe = FakePermissionProbe()
        let permissions = model(probe)
        for kind in PermissionKind.allCases { permissions.openSettings(kind) }
        XCTAssertEqual(probe.opened, PermissionKind.allCases)
    }

    // MARK: notifications are asked for at the first user run, not at launch

    func testRunningACommandPreparesNotifications() {
        let notifier = FakeNotifier()
        let manager = ProcessManager(runner: FakeCommandRunner(), notifier: notifier)
        manager.run(Command(id: UUID(), name: "c", command: "echo"))
        XCTAssertEqual(notifier.userRunPreparations, 1)
        manager.run(Chain(id: UUID(), name: "ch", commandIDs: []), commands: [:])
        XCTAssertEqual(notifier.userRunPreparations, 2)
    }

    func testAdoptionAndWatchdogDoNotPrepareNotifications() {
        let notifier = FakeNotifier()
        let manager = ProcessManager(runner: FakeCommandRunner(), notifier: notifier)
        manager.adoptSurvivingDaemons(commands: [:])
        XCTAssertEqual(notifier.userRunPreparations, 0)
    }

    // MARK: the page on the narrow macOS 15 form

    /// On macOS 15 the grouped form is 600 pt wide. SwiftUI push buttons there have no NSButton to
    /// measure, so the widest action row is budgeted from the text metrics of both languages:
    /// form insets, row padding, bezel padding and spacing included.
    func testActionRowFitsTheNarrowGroupedFormInBothLanguages() {
        let previousLanguage = LocalizationManager.shared.language
        defer { LocalizationManager.shared.language = previousLanguage }
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        func width(_ text: String) -> CGFloat { (text as NSString).size(withAttributes: [.font: font]).width }
        let available: CGFloat = 600 - 2 * 20 - 2 * 10
        for language in AppLanguage.allCases {
            LocalizationManager.shared.language = language
            let buttons = width(L10n.permissionRequest) + width(L10n.permissionOpenSettings) + 2 * 2 * 12 + 8
            XCTAssertLessThan(buttons, available, "[\(language)] action row")
            let widestState = PermissionStateSample.all.map { width(L10n.permissionState($0)) }.max() ?? 0
            XCTAssertLessThan(width(L10n.permissionStatus) + 8 + 20 + widestState, available, "[\(language)] status row")
            for kind in PermissionKind.allCases {
                XCTAssertLessThan(width(L10n.permissionTitle(kind)), available, "[\(language)] \(kind) header")
            }
        }
    }

    func testPageRendersEveryState() async throws {
        let probe = FakePermissionProbe()
        probe.states = [.accessibility: .missing, .clipboard: .askEachTime, .notifications: .notDetermined,
                        .automationGhostty: .denied, .localNetwork: .unknown, .loginItem: .needsApproval]
        var flags = PermissionFeatureFlags()
        flags.enabled = Set(PermissionFeature.allCases)
        let permissions = PermissionsModel(probe: probe, flags: { flags })
        await permissions.refresh()
        let storage = FakeRecoveryStorage()
        var saved = RecoveryState()
        saved.suspended[.clipboard] = RecoverySuspension(reason: .repeatedCrashes, since: .now)
        saved.suspended[.agentTabRestore] = RecoverySuspension(reason: .operationCrashed(.tabRestore), since: .now)
        storage.data = try RecoveryState.encode(saved)
        let recovery = RecoveryModel(storage: storage, markers: nil, bootTime: { 1 }, installedBuild: "1", notify: { _ in })
        recovery.launch()
        let hosting = NSHostingController(rootView: PermissionsView(model: permissions, recovery: recovery, refreshOnAppear: false)
            .frame(width: 600, height: 1200))
        let window = NSWindow(contentViewController: hosting)
        window.isReleasedWhenClosed = false
        window.setFrameOrigin(NSPoint(x: -2600, y: -2600))
        window.orderFront(nil)
        defer { window.close() }
        try await Task.sleep(for: .milliseconds(150))
        hosting.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(hosting.view.frame.width, 600)
        XCTAssertEqual(recovery.suspensions.map(\.module), [.clipboard, .agentTabRestore])
        XCTAssertTrue(PermissionsView.footer(permissions.row(.accessibility)).contains(L10n.permissionFeature(.brightnessKeys)))
    }

}

private enum PermissionStateSample {
    static let all: [PermissionState] = [.granted, .denied, .notDetermined, .missing, .askEachTime, .needsApproval, .off, .unknown]
}
