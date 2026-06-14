import Foundation

/// Reference to a GUI application for the "Free Memory" feature (quit before the command, relaunch after).
/// `bundleID` — stable identifier (for quit/relaunch); `name` — for display in the UI.
struct AppRef: Codable, Hashable {
    var bundleID: String
    var name: String
}
