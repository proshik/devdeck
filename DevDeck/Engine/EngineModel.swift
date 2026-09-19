import Foundation
import Observation

/// The engine DevDeck is watching right now, for the tray dot, the labels and the probe gates.
/// Refreshed by the tray's 2 s timer; the preference is read live, so a config edit (UI or by
/// hand) takes effect on the next tick without a separate hook.
@MainActor
@Observable
final class EngineModel {
    private(set) var active: (any ContainerEngine)?
    private(set) var isActiveRunning = false

    var activeKind: ContainerEngineKind? { active?.kind }
    var activeName: String? { active?.displayName }

    @ObservationIgnored var preference: () -> EnginePreference = { .auto }
    @ObservationIgnored private let candidates: [any ContainerEngine]

    init(candidates: [any ContainerEngine] = [ColimaEngine(), DockerDesktopEngine()]) {
        self.candidates = candidates
    }

    func refresh() {
        let choice = EngineSelector.select(preference(), from: candidates)
        // Assign only on change: every write notifies the popover, and this runs every 2 s.
        if choice?.engine.kind != active?.kind { active = choice?.engine }
        let running = choice?.running ?? false
        if running != isActiveRunning { isActiveRunning = running }
    }
}