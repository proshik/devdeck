import Foundation
import Observation

/// What is selected in the main window (a command or a chain).
enum MainSelection: Hashable {
    case command(UUID)
    case chain(UUID)
    case settings
    case proxy
    case cleanup
    case claudeTabs
}

/// UI state of the application (separate from data and processes).
@MainActor
@Observable
final class AppModel {
    var selection: MainSelection?
}
