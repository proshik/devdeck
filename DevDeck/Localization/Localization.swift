import Foundation
import Observation

/// Languages the UI can be switched to at runtime from Settings.
enum AppLanguage: String, CaseIterable, Identifiable {
    case en
    case ru

    var id: String { rawValue }

    /// Human-readable name shown in the language picker (always in its own language).
    var displayName: String {
        switch self {
        case .en: return "English"
        case .ru: return "Русский"
        }
    }
}

/// Single source of truth for the current UI language.
///
/// `@Observable`, so reading `language` inside a SwiftUI body registers a
/// dependency and views re-render instantly when the user switches language —
/// no app restart, no bundle/`.lproj` swapping. The choice is persisted in
/// `UserDefaults` (a pure UI preference, kept out of `config.json`).
@Observable
final class LocalizationManager {
    static let shared = LocalizationManager()

    private static let defaultsKey = "DevDeck.language"

    var language: AppLanguage {
        didSet {
            guard oldValue != language else { return }
            UserDefaults.standard.set(language.rawValue, forKey: Self.defaultsKey)
        }
    }

    init() {
        if let raw = UserDefaults.standard.string(forKey: Self.defaultsKey),
           let stored = AppLanguage(rawValue: raw) {
            language = stored
        } else {
            // First launch: follow the system preference (Russian → ru, otherwise English).
            let preferred = Locale.preferredLanguages.first ?? "en"
            language = preferred.hasPrefix("ru") ? .ru : .en
        }
    }
}

/// Picks the string for the currently selected language.
///
/// Both variants live at the call site (via the `L10n` catalog), keeping every
/// translation in one place. Reading `LocalizationManager.shared.language` here
/// is what ties SwiftUI views to the language switch.
func t(_ en: String, _ ru: String) -> String {
    LocalizationManager.shared.language == .ru ? ru : en
}
