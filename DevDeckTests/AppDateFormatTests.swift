import XCTest
@testable import DevDeck

/// Dates follow the DevDeck language, not the system one, while the region (and its clock) stays
/// the user's. Assertions use month names and the clock rather than whole strings: the exact
/// punctuation is ICU's and differs between OS versions.
@MainActor
final class AppDateFormatTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    /// 21 Nov 2026, 14:22 UTC.
    private let date = Date(timeIntervalSince1970: 1_795_270_920)
    private var previousLanguage: AppLanguage!

    override func setUp() {
        super.setUp()
        previousLanguage = LocalizationManager.shared.language
    }

    override func tearDown() {
        LocalizationManager.shared.language = previousLanguage
        super.tearDown()
    }

    func testRussianInterfaceOnAnEnglishSystemSaysTheMonthInRussian() {
        let locale = AppDateFormat.locale(.ru, base: Locale(identifier: "en_GB"))
        let text = AppDateFormat.string(date, date: .abbreviated, time: .shortened, locale: locale, timeZone: utc)
        XCTAssertTrue(text.contains("нояб"), text)
        XCTAssertTrue(text.contains("14:22"), text)
        XCTAssertFalse(text.contains("Nov"), text)
        XCTAssertFalse(text.contains(" at "), text)
        let short = AppDateFormat.dayMonthTime(date, locale: locale, timeZone: utc)
        XCTAssertTrue(short.contains("21") && short.contains("нояб") && short.contains("14:22"), short)
    }

    func testEnglishInterfaceOnARussianSystemSaysTheMonthInEnglish() {
        let locale = AppDateFormat.locale(.en, base: Locale(identifier: "ru_RU"))
        let text = AppDateFormat.string(date, date: .abbreviated, time: .shortened, locale: locale, timeZone: utc)
        XCTAssertTrue(text.contains("Nov"), text)
        XCTAssertFalse(text.contains("нояб"), text)
        // The region is still Russia: a 24-hour clock, not "2:22 PM".
        XCTAssertTrue(text.contains("14:22"), text)
        XCTAssertFalse(text.contains("PM"), text)
        let short = AppDateFormat.dayMonthTime(date, locale: locale, timeZone: utc)
        XCTAssertTrue(short.contains("Nov") && short.contains("14:22"), short)
    }

    func testOnlyTheLanguageIsReplacedTheRegionStays() {
        let ru = AppDateFormat.locale(.ru, base: Locale(identifier: "en_US"))
        XCTAssertEqual(ru.language.languageCode?.identifier, "ru")
        XCTAssertEqual(ru.region?.identifier, "US")
        let en = AppDateFormat.locale(.en, base: Locale(identifier: "en_US"))
        let text = AppDateFormat.string(date, date: .omitted, time: .shortened, locale: en, timeZone: utc)
        XCTAssertTrue(text.contains("2:22") && text.contains("PM"), "a US region keeps its 12-hour clock: \(text)")
    }

    func testTheDefaultLocaleFollowsTheLiveLanguageSwitch() {
        let base = Locale(identifier: "en_GB")
        LocalizationManager.shared.language = .ru
        XCTAssertEqual(AppDateFormat.locale(base: base).language.languageCode?.identifier, "ru")
        LocalizationManager.shared.language = .en
        XCTAssertEqual(AppDateFormat.locale(base: base).language.languageCode?.identifier, "en")
    }

    /// A caller that formats on its own through the default arguments: the recovery banner.
    func testRecoveryReasonFollowsTheLanguage() {
        LocalizationManager.shared.language = .ru
        let ru = L10n.recoveryReason(.repeatedCrashes, since: date)
        XCTAssertTrue(ru.contains("нояб"), ru)
        LocalizationManager.shared.language = .en
        let en = L10n.recoveryReason(.repeatedCrashes, since: date)
        XCTAssertTrue(en.contains("Nov"), en)
    }
}
