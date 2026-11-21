import Foundation

/// Every date and time DevDeck shows goes through here, so it follows the DevDeck language
/// (`LocalizationManager`, switched live in Settings) instead of the system language: a Russian
/// interface on an English system says «21 нояб. 2026 г., 14:22», not «21 Nov 2026 at 14:22».
///
/// Only the language is swapped. The rest of the system locale — the region, and with it the
/// 12/24-hour clock and the order of day and month — stays the user's, the same split macOS makes
/// between Language and Region. Reading `LocalizationManager.shared.language` inside a view's body
/// is what re-renders the dates on a language switch.
enum AppDateFormat {
    /// The base locale with its language replaced by the DevDeck one. Also the `\.locale` for views
    /// that format dates themselves (Swift Charts axes).
    static func locale(_ language: AppLanguage = LocalizationManager.shared.language,
                       base: Locale = .autoupdatingCurrent) -> Locale {
        var components = Locale.Components(locale: base)
        // Only the code: `languageComponents` also carries the region, which stays the user's.
        components.languageComponents.languageCode = Locale.LanguageCode(language.rawValue)
        return Locale(components: components)
    }

    /// A date and/or time in one of the standard lengths.
    static func string(_ value: Date, date: Date.FormatStyle.DateStyle, time: Date.FormatStyle.TimeStyle,
                       locale: Locale = locale(), timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle(date: date, time: time).locale(locale)
        style.timeZone = timeZone
        return value.formatted(style)
    }

    /// Day, abbreviated month and time without the year — for lists of recent items.
    static func dayMonthTime(_ value: Date, locale: Locale = locale(),
                             timeZone: TimeZone = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle.dateTime.day().month().hour().minute().locale(locale)
        style.timeZone = timeZone
        return value.formatted(style)
    }
}
