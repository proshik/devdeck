import Foundation
import Observation

/// One row of the permissions page.
struct PermissionRow: Identifiable, Equatable {
    struct Feature: Equatable {
        let feature: PermissionFeature
        let isEnabled: Bool
    }
    let kind: PermissionKind
    let state: PermissionState
    let features: [Feature]
    /// A system prompt is offered only while one of the permission's features is on and the
    /// system can still ask (REC-01).
    let canRequest: Bool
    var id: PermissionKind { kind }
}

/// Actual permission states for the permissions page, re-read on demand (page shown, app
/// activated, after a prompt) rather than polled.
@MainActor
@Observable
final class PermissionsModel {
    private(set) var states: [PermissionKind: PermissionState] = [:]
    @ObservationIgnored private let probe: any PermissionProbing
    @ObservationIgnored private let flags: () -> PermissionFeatureFlags
    /// Feature flags as of the last refresh; observed so rows follow the settings.
    private var currentFlags = PermissionFeatureFlags()

    init(probe: any PermissionProbing, flags: @escaping () -> PermissionFeatureFlags) {
        self.probe = probe
        self.flags = flags
    }

    var rows: [PermissionRow] { PermissionKind.allCases.map(row) }

    func row(_ kind: PermissionKind) -> PermissionRow {
        let state = states[kind] ?? .unknown
        let enabled = currentFlags.enabled
        let features = kind.features.map { PermissionRow.Feature(feature: $0, isEnabled: enabled.contains($0)) }
        let canRequest = kind.hasPrompt && state.isPromptable && features.contains(where: \.isEnabled)
        return PermissionRow(kind: kind, state: state, features: features, canRequest: canRequest)
    }

    func refresh() async {
        currentFlags = flags()
        var next: [PermissionKind: PermissionState] = [:]
        for kind in PermissionKind.allCases { next[kind] = await probe.state(of: kind) }
        states = next
    }

    func request(_ kind: PermissionKind) async {
        currentFlags = flags()
        guard row(kind).canRequest else { return }
        await probe.request(kind)
        await refresh()
    }

    func openSettings(_ kind: PermissionKind) { probe.openSettings(kind) }
}
