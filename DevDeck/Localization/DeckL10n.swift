import Foundation

extension L10n {
    static var deckEnvironment: String { t("Environment", "Среда") }
    static var deckCommands: String { t("Commands & Chains", "Команды и цепочки") }
    static var deckAdd: String { t("Add", "Добавить") }
    static var deckSessionsDisabled: String { t("Off", "Выключено") }
    static func deckSavedTabs(_ count: Int) -> String {
        t("Saved tabs: \(count)", "Сохранено вкладок: \(count)")
    }
    static var deckMonitoring: String { t("Monitoring", "Мониторинг") }
    static var deckDisplays: String { t("Displays", "Экраны") }
    static var deckThisMac: String { t("This Mac", "Этот Mac") }
    static var deckContainers: String { t("Containers", "Контейнеры") }
    static var deckEnergy: String { t("Energy", "Питание") }
    static var deckGeneral: String { t("General", "Общие") }
    static var deckPanel: String { t("Panel & Modules", "Панель и модули") }
    static var deckUpdates: String { t("DevDeck Updates", "Обновления DevDeck") }
    static var deckPorts: String { t("Port Forwards", "Пробросы портов") }
    static var deckObservation: String { t("Observation", "Наблюдение") }
    static var deckMacTools: String { t("Mac Tools", "Инструменты Mac") }
    static var deckSettings: String { t("DevDeck Settings…", "Настройки DevDeck…") }
    static var deckDiagnosticLog: String { t("Show diagnostic log…", "Показать журнал диагностики…") }
    static var deckPanelSettings: String { t("Configure panel…", "Настроить панель…") }
    static var deckSection: String { t("Panel section", "Раздел панели") }
    static var deckDetails: String { t("Details…", "Подробнее…") }
    static var deckNoData: String { t("No measurement", "Нет измерения") }
    static var deckCollectionOff: String { t("Monitoring is disabled", "Мониторинг выключен") }
    static var deckEngineStatus: String { t("Engine", "Движок") }
    static var deckEngineRunning: String { t("Running", "Работает") }
    static var deckEngineStopped: String { t("Stopped", "Остановлен") }
    static var deckNoPortForwards: String { t("No commands with a configured port", "Нет команд с настроенным портом") }
    static var deckPanelDescription: String {
        t("Quick controls live in the menu bar. Editors, logs and full settings open in this window.",
          "Быстрые действия доступны в строке меню. Редакторы, логи и полные настройки открываются в этом окне.")
    }
    static var deckVersion: String { t("Installed version", "Установленная версия") }
    static var deckNotChecked: String { t("Updates have not been checked yet", "Обновления ещё не проверены") }
    static var deckChecking: String { t("Checking for updates…", "Проверка обновлений…") }
    static var deckLastCheck: String { t("Last check", "Последняя проверка") }
    static var deckLoginError: String { t("Could not change launch at login", "Не удалось изменить запуск при входе") }
    static var deckIsolated: String { t("Isolated development launch", "Изолированный запуск для разработки") }
    static var deckDevelopmentTitle: String { t("DevDeck — Development", "DevDeck — разработка") }
    static var deckDevelopmentUpdates: String {
        t("Automatic updates are disabled in this development launch.",
          "Автоматические обновления отключены в этом запуске для разработки.")
    }

    static func deckStatus(_ status: DeckStatus) -> String {
        switch status {
        case .idle: t("Idle", "Не запущено")
        case .running: t("Running", "Выполняется")
        case .daemon: t("Running in background", "Работает в фоне")
        case .failed: t("Failed", "Ошибка")
        }
    }
}
