import Foundation
extension L10n {
    static var monitoringEnabled: String { t("Collect monitoring data", "Собирать показатели") }
    static var monitoringHistory: String { t("Keep recent history", "Хранить недавнюю историю") }
    static var monitoringInterval: String { t("Sampling interval (seconds)", "Интервал измерений (секунды)") }
    static var monitoringHistoryHelp: String { t("Up to 180 samples in memory. Container probes run at most every 15 seconds. Collection requires an open panel or monitoring page; build alerts and battery accounting work independently.", "До 180 измерений в памяти. Контейнерные пробы — не чаще раза в 15 секунд. Сбор работает при открытой панели или странице мониторинга; предупреждения сборок и учёт батареи независимы.") }
    static var monitoringLast: String { t("Last measurement", "Последнее измерение") }
    static var monitoringUpdated: String { t("Measured", "Измерено") }
    static var monitoringUnavailable: String { t("Unavailable", "Недоступно") }
    static var monitoringMissing: String { t("The source has not supplied a valid measurement.", "Источник не предоставил корректное измерение.") }
    static var monitoringCPU: String { t("CPU busy", "Загрузка CPU") }
    static var monitoringLoad: String { t("Load average · 1 min", "Load average · 1 мин") }
    static var monitoringDisk: String { t("Root disk · used / total", "Корневой диск · занято / всего") }
    static func monitoringDiskValue(used: UInt64, total: UInt64) -> String {
        String(format: "%.1f / %.1f ", Double(used) / 1_073_741_824, Double(total) / 1_073_741_824) + t("GiB", "ГиБ")
    }
    static func monitoringSwapRate(input: Double, output: Double) -> String {
        String(format: "↑ %.1f · ↓ %.1f ", output / 1_048_576, input / 1_048_576) + t("MiB/s", "МиБ/с")
    }
    static var monitoringMemoryOff: String { t("Memory collection is off", "Сбор показателей памяти выключен") }
    static func monitoringUptimeValue(_ seconds: TimeInterval) -> String {
        let minutes = Int(max(0, seconds)) / 60
        return t(String(format: "%dd %02dh %02dm", minutes / 1440, (minutes / 60) % 24, minutes % 60),
                 String(format: "%dд %02dч %02dмин", minutes / 1440, (minutes / 60) % 24, minutes % 60))
    }
    static var monitoringUptime: String { t("Uptime", "Время работы") }
    static var monitoringTemperature: String { t("Physical temperature", "Физическая температура") }
    static var monitoringUnsupported: String { t("No supported native source; no helper installed.", "Нет поддерживаемого нативного источника; helper не установлен.") }
    static var monitoringCycles: String { t("Battery cycles", "Циклы батареи") }
    static var monitoringHealth: String { t("Battery condition", "Состояние батареи") }
    static var monitoringAdapter: String { t("Adapter rating", "Номинал адаптера") }
    static var monitoringBatteryPower: String { t("Battery power", "Мощность батареи") }
    static var monitoringPowerHelp: String { t("Battery terminal power: + charging, − discharging. The adapter rating is its nominal capacity, not the Mac’s consumption.", "Мощность на батарее: + заряд, − разряд. Номинал адаптера — его паспортная мощность, не потребление Mac.") }
    static var monitoringEnergyShare: String { t("Share of accounted process energy", "Доля учтённой энергии процессов") }
    static var monitoringHistoryTitle: String { t("Recent measurements · %", "Недавние измерения · %") }
    static var monitoringWaitingHistory: String { t("Waiting for measurements", "Ожидание измерений") }
}
