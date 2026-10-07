import Foundation

extension L10n {
    static var panelNewTab: String { t("New tab", "Новая вкладка") }
    static var panelAddTab: String { t("Add tab…", "Добавить вкладку…") }
    static var panelEditTab: String { t("Rename and change icon…", "Изменить название и иконку…") }
    static var panelTabName: String { t("Tab name", "Название вкладки") }
    static var panelTabIcon: String { t("Icon", "Иконка") }
    static var panelGridIcon: String { t("Modules", "Модули") }
    static var panelFavoriteIcon: String { t("Favorites", "Избранное") }
    static var panelRemoveTab: String { t("Remove tab", "Удалить вкладку") }
    static var panelRemoveTabHelp: String { t("Remove tab; its modules return to Available modules", "Удалить вкладку; её модули вернутся в доступные") }
    static var panelRemoveModule: String { t("Remove from panel", "Удалить из панели") }
    static var panelAvailableModules: String { t("Available modules", "Доступные модули") }
    static var panelAllModulesAdded: String { t("All modules have been added. Remove one from a tab to return it here.", "Все модули добавлены. Удалите модуль из вкладки, чтобы вернуть его сюда.") }
    static var panelNoTabs: String { t("Add a tab, then add modules from the catalogue below.", "Добавьте вкладку, затем выберите модули из каталога ниже.") }
    static var panelAddModule: String { t("Add module", "Добавить модуль") }
    static var panelAddTo: String { t("Add to", "Добавить в") }
    static var panelHide: String { t("Hide in panel", "Скрыть в панели") }
    static var panelShow: String { t("Show in panel", "Показывать в панели") }
    static var panelMoveTo: String { t("Move to", "Перенести в") }
    static var panelMoveUp: String { t("Move up", "Переместить вверх") }
    static var panelMoveDown: String { t("Move down", "Переместить вниз") }
    static var panelBehavior: String { t("Panel behavior", "Поведение панели") }
    static var panelRememberLast: String { t("Return to the last section", "Возвращаться на последнюю вкладку") }
    static var panelInitialSection: String { t("Initial section", "Начальная вкладка") }
    static var panelMemoryInEnvironment: String { t("Show memory in Environment", "Показывать память во вкладке «Среда»") }
    static var panelRestoreLayout: String { t("Restore standard layout", "Восстановить стандартное расположение") }
    static var panelDragSection: String { t("Drag to reorder sections", "Перетащите для изменения порядка вкладок") }
    static var panelSectionActions: String { t("Section order", "Порядок вкладок") }
    static var panelModuleActions: String { t("Move, hide or remove module", "Перенести, скрыть или удалить модуль") }
    static var panelShowSection: String { t("Show section in panel", "Показывать вкладку в панели") }
    static func panelShowModule(_ name: String) -> String { t("Show \(name) in panel", "Показывать «\(name)» в панели") }
    static var panelDropModules: String { t("Drag modules here", "Перетащите сюда модули") }
    static var panelDropHere: String { t("Drop here to add at the end", "Перетащите сюда для добавления в конец") }
    static var panelArrangementHelp: String { t("Drag modules and tab headings to rearrange them, or use the ⋯ menus.", "Переставляйте модули и заголовки вкладок перетаскиванием или через меню ⋯.") }
    static var panelVisibilityHelp: String { t("Hiding or removing modules only changes the panel. Running commands, ports and proxies continue working; data collection is configured on each function’s page.", "Скрытие и удаление модулей меняют только панель. Работающие команды, порты и прокси продолжают работать; сбор данных настраивается на странице каждой функции.") }
    static var panelEmpty: String { t("The panel is empty", "Панель пуста") }
    static var panelNoItems: String { t("No items", "Нет элементов") }
    static var panelManage: String { t("Manage…", "Управление…") }
    static func panelHiddenActivity(_ count: Int) -> String { t("Active hidden modules: \(count)", "Активных скрытых модулей: \(count)") }
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
