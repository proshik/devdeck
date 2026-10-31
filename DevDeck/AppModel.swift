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
    case clipboard
    case displays
}

/// UI state of the application (separate from data and processes).
@MainActor
@Observable
final class AppModel {
    var selection: MainSelection? = .settings
    var panelSection: PanelSection = .environment
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

struct PanelSection: RawRepresentable, Hashable, Codable, CaseIterable, Identifiable, Sendable {
    let rawValue: String
    static let environment = Self(rawValue: "environment")!
    static let monitoring = Self(rawValue: "monitoring")!
    static let displays = Self(rawValue: "displays")!
    static let clipboard = Self(rawValue: "clipboard")!
    static let allCases: [Self] = [.environment, .monitoring, .displays, .clipboard]

    init?(rawValue: String) {
        guard ["environment", "monitoring", "displays", "clipboard"].contains(rawValue)
                || (rawValue.hasPrefix("custom-") && UUID(uuidString: String(rawValue.dropFirst(7))) != nil) else { return nil }
        self.rawValue = rawValue
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        guard let section = Self(rawValue: value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid panel section ID")
        }
        self = section
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
    var id: String { rawValue }
    var title: String {
        switch self {
        case .environment: L10n.deckEnvironment
        case .monitoring: L10n.deckMonitoring
        case .displays: L10n.deckDisplays
        case .clipboard: L10n.clipboardTab
        default: L10n.panelNewTab
        }
    }
    var symbol: String {
        switch self {
        case .environment: "terminal"
        case .monitoring: "waveform.path.ecg"
        case .displays: "display"
        case .clipboard: "clipboard"
        default: "square.grid.2x2"
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
