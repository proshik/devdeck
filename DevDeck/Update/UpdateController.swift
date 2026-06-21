import AppKit
import Observation
import Sparkle

extension Bundle {
    /// Marketing version, e.g. "0.3.0" (CFBundleShortVersionString).
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0" }
    /// Build number Sparkle actually compares (CFBundleVersion).
    var buildVersion: String { infoDictionary?["CFBundleVersion"] as? String ?? "0" }
}

/// Pure summary of how far behind the installed build is. Build numbers are monotonic integers
/// (CFBundleVersion = git commit count), so a numeric compare matches Sparkle's ordering. Sparkle-free
/// so it is unit-testable without the framework.
func appcastSummary(installedBuild: Int, items: [(build: Int, display: String)]) -> (behind: Int, latest: String?) {
    let newer = items.filter { $0.build > installedBuild }
    return (newer.count, newer.max(by: { $0.build < $1.build })?.display)
}

/// Owns Sparkle and exposes update state to the UI. Pattern mirrors `AppearanceManager`.
///
/// Behaviour the user wants:
/// - auto-update ON  → Sparkle silently downloads + installs (`automaticallyDownloadsUpdates`);
/// - auto-update OFF → a SILENT check (`checkForUpdateInformation`) only populates the indicator
///   (`latestVersion` / `releasesBehind`); the user installs from the popover/Settings on demand.
///
/// Sparkle invokes `SPUUpdaterDelegate` callbacks on the main thread, so mutating the observable
/// state directly from them is safe.
@Observable
final class UpdateController: NSObject, SPUUpdaterDelegate {
    @ObservationIgnored private var controller: SPUStandardUpdaterController!

    /// Installed marketing version (e.g. "0.3.0").
    let currentVersion: String
    /// Newest available marketing version, when known.
    private(set) var latestVersion: String?
    /// How many published releases are newer than the installed build.
    private(set) var releasesBehind: Int = 0
    var updateAvailable: Bool { releasesBehind > 0 }

    override init() {
        currentVersion = Bundle.main.shortVersion
        super.init()
        // Wire the delegate before the updater starts so the first scheduled check is observed.
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
    }

    /// Apply the persisted preference and start Sparkle. Call once after settings have loaded.
    func configure(autoUpdateEnabled: Bool) {
        let updater = controller.updater
        updater.automaticallyChecksForUpdates = true          // always check (needed for the indicator)
        updater.automaticallyDownloadsUpdates = autoUpdateEnabled
        do {
            try updater.start()
        } catch {
            DiagnosticLog.shared.log("Sparkle failed to start: \(error.localizedDescription)", level: .warn)
        }
        if !autoUpdateEnabled { checkSilently() }
    }

    func setAutoUpdateEnabled(_ on: Bool) {
        controller.updater.automaticallyDownloadsUpdates = on
        if !on { checkSilently() }
    }

    /// Silent background probe — populates `latestVersion` / `releasesBehind` without any UI.
    func checkSilently() {
        controller.updater.checkForUpdateInformation()
    }

    /// User-initiated check that shows Sparkle's standard install UI.
    func checkForUpdatesUserInitiated() {
        controller.checkForUpdates(nil)
    }

    // MARK: - SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFinishLoading appcast: SUAppcast) {
        // Sparkle compares CFBundleVersion; our build numbers are monotonic integers (git commit count).
        let installed = Int(Bundle.main.buildVersion) ?? 0
        let items = appcast.items.compactMap { item -> (build: Int, display: String)? in
            guard let build = Int(item.versionString) else { return nil }
            return (build, item.displayVersionString)
        }
        let summary = appcastSummary(installedBuild: installed, items: items)
        releasesBehind = summary.behind
        latestVersion = summary.latest
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        releasesBehind = 0
        latestVersion = currentVersion
    }
}
