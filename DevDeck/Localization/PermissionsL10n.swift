import Foundation

/// Strings for the permissions page (stage 9, REC-01).
extension L10n {
    static var permissionsTitle: String { t("Permissions", "Разрешения") }
    static var permissionsIntro: String {
        t("DevDeck asks for a permission only when you turn on a feature that needs it. Losing one affects only its features.",
          "DevDeck запрашивает разрешение, только когда вы включаете функцию, которой оно нужно. Без разрешения не работают только его функции.")
    }
    static var permissionStatus: String { t("Status", "Состояние") }
    static var permissionRequest: String { t("Request…", "Запросить…") }
    static var permissionOpenSettings: String { t("Open System Settings", "Открыть Системные настройки") }

    static func permissionTitle(_ kind: PermissionKind) -> String {
        switch kind {
        case .accessibility: t("Accessibility", "Универсальный доступ")
        case .clipboard: t("Pasteboard access", "Доступ к буферу обмена")
        case .notifications: t("Notifications", "Уведомления")
        case .automationGhostty: t("Automation: Ghostty", "Автоматизация: Ghostty")
        case .localNetwork: t("Local network", "Локальная сеть")
        case .loginItem: t("Open at login", "Открывать при входе")
        }
    }

    static func permissionState(_ state: PermissionState) -> String {
        switch state {
        case .granted: t("Allowed", "Разрешено")
        case .denied: t("Denied", "Запрещено")
        case .notDetermined: t("Not asked yet", "Ещё не запрошено")
        case .missing: t("Not allowed", "Не разрешено")
        case .askEachTime: t("Asks each time", "Спрашивает каждый раз")
        case .needsApproval: t("Needs approval", "Требует одобрения")
        case .off: t("Off", "Выключено")
        case .unknown: t("Unknown", "Неизвестно")
        }
    }

    static func permissionFeature(_ feature: PermissionFeature) -> String {
        switch feature {
        case .brightnessKeys: t("brightness keys", "клавиши яркости")
        case .clipboardPaste: t("paste from history", "вставка из истории")
        case .clipboardHistory: t("clipboard history", "история буфера")
        case .commandNotifications: t("command and daemon events", "события команд и демонов")
        case .agentTabsRestore: t("agent tab restore", "восстановление вкладок агентов")
        case .terminalCommands: t("commands run in Ghostty", "команды в Ghostty")
        case .proxyDiscovery: t("proxy discovery", "поиск прокси")
        case .proxyShare: t("proxy sharing", "раздача прокси")
        case .launchAtLogin: t("start with macOS", "запуск вместе с macOS")
        }
    }

    static var permissionFeatureOn: String { t("on", "включено") }
    static var permissionFeatureOff: String { t("off", "выключено") }

    static func permissionUsedBy(_ list: String) -> String { t("Used by: \(list).", "Нужно для: \(list).") }

    /// What the state cannot tell, per permission.
    static func permissionNote(_ kind: PermissionKind) -> String? {
        switch kind {
        case .accessibility:
            t("macOS does not tell “denied” from “not asked”. After DevDeck is replaced by a new build, remove it from the list and add it again.",
              "macOS не отличает «запрещено» от «не запрошено». После замены DevDeck новой сборкой удалите его из списка и добавьте снова.")
        case .clipboard:
            t("Copying from DevDeck works without this permission; reading other apps’ content needs it.",
              "Копирование из DevDeck работает без разрешения; оно нужно для чтения содержимого других приложений.")
        case .notifications:
            t("Asked for the first time you run a command or daemon.",
              "Запрашивается при первом запуске команды или демона.")
        case .automationGhostty:
            t("The state is known only while Ghostty is running.",
              "Состояние известно, только пока Ghostty запущен.")
        case .localNetwork:
            t("macOS has no way to ask for this in advance: the state is known after proxy discovery or sharing has run.",
              "У macOS нет способа узнать это заранее: состояние известно после работы поиска или раздачи прокси.")
        case .loginItem:
            t("Turned on and off in General settings.", "Включается и выключается в общих настройках.")
        }
    }
}
