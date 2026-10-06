import Foundation
import Observation

/// What is selected in the main window (a command or a chain).
enum MainSelection: Hashable {
    case command(UUID)
    case chain(UUID)
    case commands
    case settings
    case proxy
    case cleanup
    case claudeTabs
    case panel
    case updates
    case monitoring
    case containers
    case energy
    case awake
    case ports
}

/// UI state of the application (separate from data and processes).
@MainActor
@Observable
final class AppModel {
    var selection: MainSelection? = .settings
    var panelSection: PanelSection = .environment
    var monitoringSection: MonitoringSection = .mac
    var detailTab: DetailTab = .editor
    var panelContentHeightLimit: CGFloat = 560
    @ObservationIgnored var dismissPanel: () -> Void = {}
    @ObservationIgnored lazy var mainWindowActivation = MainWindowActivationController()

    /// Closing a popover is explicit: activating another window of the same app does not
    /// reliably dismiss a transient NSPopover.
    func showMainWindow(selection: MainSelection? = nil, open: () -> Void) {
        if let selection { self.selection = selection }
        dismissPanel()
        mainWindowActivation.prepareToOpen()
        open()
    }
}

enum DetailTab: Hashable { case editor, logs }

enum PanelSection: String, CaseIterable, Identifiable {
    case environment, monitoring, displays
    var id: String { rawValue }
    var title: String {
        switch self {
        case .environment: L10n.deckEnvironment
        case .monitoring: L10n.deckMonitoring
        case .displays: L10n.deckDisplays
        }
    }
    var symbol: String {
        switch self {
        case .environment: "terminal"
        case .monitoring: "waveform.path.ecg"
        case .displays: "display"
        }
    }
}

enum MonitoringSection: String, CaseIterable, Identifiable {
    case mac, containers, energy
    var id: String { rawValue }
    var title: String {
        switch self {
        case .mac: L10n.deckThisMac
        case .containers: L10n.deckContainers
        case .energy: L10n.deckEnergy
        }
    }
}
