import Foundation

/// Strings for crash recovery (stage 9, REC-01).
extension L10n {
    static var recoverySection: String { t("Recovery", "Восстановление") }
    static var recoveryBanner: String {
        t("Some modules were switched off after repeated failures", "Часть модулей отключена после повторных сбоев")
    }
    static var recoveryShow: String { t("Show", "Показать") }
    static var recoveryResume: String { t("Turn On Again", "Включить снова") }
    static var recoveryResumeAll: String { t("Turn All On", "Включить все") }
    static var recoveryNothing: String {
        t("No module is switched off.", "Ни один модуль не отключён.")
    }
    static var recoveryHelp: String {
        t("After repeated failures DevDeck switches off only its additional modules; commands, daemons, chains and proxies keep working. Your settings, config.json and the session snapshot are kept. Modules come back only when you turn them on here.",
          "После повторных сбоев DevDeck отключает только дополнительные модули; команды, демоны, цепочки и прокси продолжают работать. Настройки, config.json и снимок сессий сохраняются. Модули возвращаются, только когда вы включите их здесь.")
    }

    static func recoveryModule(_ module: RecoveryModule) -> String {
        switch module {
        case .clipboard: t("Clipboard history", "История буфера")
        case .brightness: t("Display brightness and keys", "Яркость экранов и клавиши")
        case .monitoring: t("Monitoring", "Мониторинг")
        case .network: t("Network traffic", "Трафик сети")
        case .agentTabRestore: t("Agent tab restore", "Восстановление вкладок агентов")
        case .autoUpdateInstall: t("Automatic update install", "Автоустановка обновлений")
        case .automationCLI: t("Command line automation", "Автоматизация из командной строки")
        }
    }

    static func recoveryOperation(_ operation: RecoveryOperation) -> String {
        switch operation {
        case .tabRestore: t("restoring agent tabs", "восстановление вкладок агентов")
        case .heavyProbes: t("container probes", "проверки контейнеров")
        case .displayDiscovery: t("display discovery", "обнаружение экранов")
        case .updateInstall: t("installing an update", "установка обновления")
        }
    }

    static func recoveryReason(_ reason: RecoverySuspensionReason, since: Date) -> String {
        let time = AppDateFormat.string(since, date: .abbreviated, time: .shortened)
        switch reason {
        case .operationCrashed(.updateInstall):
            return t("The update did not install twice · \(time)", "Обновление дважды не установилось · \(time)")
        case .operationCrashed(let operation):
            return t("DevDeck quit unexpectedly twice during \(recoveryOperation(operation)) · \(time)",
                     "DevDeck дважды неожиданно завершился во время: \(recoveryOperation(operation)) · \(time)")
        case .repeatedCrashes:
            return t("DevDeck quit unexpectedly three times in a row soon after launch · \(time)",
                     "DevDeck трижды подряд неожиданно завершился вскоре после запуска · \(time)")
        }
    }

    static var notifModulesSuspended: String {
        t("DevDeck switched off modules after failures", "DevDeck отключил модули после сбоев")
    }
}
