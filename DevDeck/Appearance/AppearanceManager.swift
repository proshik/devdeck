import AppKit
import Observation

/// UI appearance modes selectable from Settings.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system: return L10n.appearanceSystem
        case .light: return L10n.appearanceLight
        case .dark: return L10n.appearanceDark
        }
    }

    /// nil = follow the OS (no override).
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// Single source of truth for the UI appearance. `@Observable` so the Settings picker re-renders;
/// the choice is persisted in `UserDefaults` (a pure UI preference, kept out of `config.json`).
/// Setting it applies app-wide via `NSApp.appearance` (all windows + the popover).
@MainActor
@Observable
final class AppearanceManager {
    static let shared = AppearanceManager()

    private static let defaultsKey = "DevDeck.appearance"

    var appearance: AppAppearance {
        didSet {
            guard oldValue != appearance else { return }
            UserDefaults.standard.set(appearance.rawValue, forKey: Self.defaultsKey)
            apply()
        }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let stored = AppAppearance(rawValue: raw) {
            appearance = stored
        } else {
            appearance = .system
        }
    }

    /// Apply the current choice to the whole app. Call once at launch and on every change.
    func apply() {
        NSApp.appearance = appearance.nsAppearance
    }
}
