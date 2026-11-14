import Foundation
extension L10n {
    static var networkRateUnit: String { t("B/s", "Б/с") }
    static var networkTitle: String { t("Network", "Сеть") }
    static var networkInterface: String { t("Interface", "Интерфейс") }
    static var networkAutomatic: String { t("Automatic", "Автоматически") }
    static func networkSource(_ name: String) -> String { t("Source: ", "Источник: ") + name }
    static var networkTraffic: String { t("Interface traffic · includes LAN", "Трафик интерфейса · включая LAN") }
    static var networkReceive: String { t("Received", "Получено") }
    static var networkSend: String { t("Sent", "Отправлено") }
    static var networkSession: String { t("Observed session volume", "Объём за сеанс наблюдения") }
    static var networkCollect: String { t("Collect interface traffic", "Собирать трафик интерфейса") }
    static var networkTest: String { t("Test internet quality", "Проверить качество интернета") }
    static var networkTestHelp: String { t("networkQuality uses internet bandwidth for up to 30 seconds. Capacity in Mbit/s, responsiveness under load in RPM, idle latency in ms. Starts only on request; independent of command proxy routing.", "networkQuality расходует интернет-трафик до 30 секунд. Пропускная способность — Мбит/с, отзывчивость под нагрузкой — RPM, задержка без нагрузки — мс. Только по запросу; независимо от прокси команд.") }
    static var networkRunning: String { t("Measuring…", "Измерение…") }
    static var networkCapacity: String { t("Capacity ↓ / ↑ · Mbit/s", "Пропускная способность ↓ / ↑ · Мбит/с") }
    static var networkResponsiveness: String { t("Responsiveness · RPM", "Отзывчивость · RPM") }
    static var networkLatency: String { t("Idle latency · ms", "Задержка без нагрузки · мс") }
    static func networkError(_ error: NetworkQualityFailure) -> String {
        switch error {
        case .cancelled: t("Test cancelled", "Проверка отменена")
        case .timeout: t("Test timed out", "Истекло время проверки")
        case .network: t("Network test failed. Check the connection.", "Ошибка проверки сети. Проверьте подключение.")
        case .unavailable: t("networkQuality is unavailable", "networkQuality недоступен")
        case .invalidOutput: t("No valid networkQuality result", "Нет корректного результата networkQuality")
        }
    }
    static func networkBytes(_ value: Double, rate: Bool = false) -> String {
        let units = rate ? t("KiB/s", "КиБ/с") : t("MiB", "МиБ")
        return String(format: "%.1f ", value / (rate ? 1024 : 1048576)) + units
    }
}
