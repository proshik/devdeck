import Foundation

/// Strings for Shortcuts automation (stage 8): the settings switch, the per-item flag,
/// refusals and the `message` line of an action's result.
extension L10n {
    static var automationSection: String { t("Automation", "Автоматизация") }
    static var automationToggle: String { t("Accept requests from Shortcuts", "Принимать запросы из Shortcuts") }
    static var automationHelp: String {
        t("Shortcuts, the `shortcuts run` command and coding agents can run, stop and read only the commands and chains marked “Allow from Shortcuts”. Arbitrary shell commands are never accepted.",
          "Shortcuts, команда `shortcuts run` и coding agents могут запускать, останавливать и опрашивать только команды и цепочки с флажком «Разрешить из Shortcuts». Произвольные shell-команды не принимаются.")
    }
    static var allowFromShortcutsToggle: String { t("Allow from Shortcuts", "Разрешить из Shortcuts") }
    static var automationUnknownItem: String { t("Unknown DevDeck item", "Неизвестный элемент DevDeck") }

    // MARK: refusals

    static var automationDisabledMessage: String {
        t("Automation is turned off in DevDeck Settings.", "Автоматизация выключена в настройках DevDeck.")
    }
    static func automationCommandNotFound(_ id: UUID) -> String {
        t("There is no DevDeck command with id \(id.uuidString): it was deleted or the shortcut is out of date.",
          "Команды DevDeck с id \(id.uuidString) нет: она удалена или ярлык устарел.")
    }
    static func automationChainNotFound(_ id: UUID) -> String {
        t("There is no DevDeck chain with id \(id.uuidString): it was deleted or the shortcut is out of date.",
          "Цепочки DevDeck с id \(id.uuidString) нет: она удалена или ярлык устарел.")
    }
    static func automationCommandNotAllowed(_ name: String) -> String {
        t("Command “\(name)” is not allowed from Shortcuts. Turn on “Allow from Shortcuts” in its editor.",
          "Команда «\(name)» не разрешена из Shortcuts. Включите «Разрешить из Shortcuts» в её редакторе.")
    }
    static func automationChainNotAllowed(_ name: String) -> String {
        t("Chain “\(name)” is not allowed from Shortcuts. Turn on “Allow from Shortcuts” in its editor.",
          "Цепочка «\(name)» не разрешена из Shortcuts. Включите «Разрешить из Shortcuts» в её редакторе.")
    }
    static func automationDirectoryRequired(_ name: String) -> String {
        t("“\(name)” asks for a working directory: pass it in the Directory parameter.",
          "«\(name)» запрашивает рабочий каталог: передайте его в параметре Directory.")
    }
    static func automationDirectoryMissing(_ path: String) -> String {
        t("Directory “\(path)” does not exist. An absolute path is required.",
          "Каталога «\(path)» нет. Нужен абсолютный путь.")
    }
    static func automationDirectoryNotAccepted(_ name: String) -> String {
        t("“\(name)” does not ask for a directory; the Directory parameter is only for commands that do.",
          "«\(name)» не запрашивает каталог; параметр Directory — только для таких команд.")
    }
    static func automationPortOccupied(_ port: Int, _ process: String, _ pid: Int32) -> String {
        t("Port \(port) is occupied by \(process) (PID \(pid)); the command was not started.",
          "Порт \(port) занят процессом \(process) (PID \(pid)); команда не запущена.")
    }
    static func automationProxyUnavailable(_ name: String) -> String {
        t("“\(name)” must go through a proxy, but none is available; it was not started.",
          "«\(name)» должна идти через прокси, но доступного прокси нет; команда не запущена.")
    }
    static func automationSudoDaemon(_ name: String) -> String {
        t("“\(name)” is a sudo daemon, which DevDeck cannot run.",
          "«\(name)» — sudo-демон, такой запуск DevDeck не поддерживает.")
    }
    static var automationNotReady: String {
        t("DevDeck is still starting. Try again in a moment.", "DevDeck ещё запускается. Повторите чуть позже.")
    }

    // MARK: results

    static func automationSucceeded(_ name: String) -> String {
        t("“\(name)” finished successfully.", "«\(name)» завершилась успешно.")
    }
    static func automationFailed(_ name: String, _ code: Int32) -> String {
        t("“\(name)” failed with exit code \(code).", "«\(name)» завершилась с ошибкой, код \(code).")
    }
    static func automationDaemonFailed(_ name: String, _ code: Int32) -> String {
        t("Background “\(name)” stopped with exit code \(code).", "Фоновая «\(name)» остановилась, код \(code).")
    }
    static func automationChainFailed(_ name: String, _ step: Int, _ stepName: String, _ code: Int32) -> String {
        t("Chain “\(name)” failed at step \(step) “\(stepName)” (exit code \(code)).",
          "Цепочка «\(name)» упала на шаге \(step) «\(stepName)» (код \(code)).")
    }
    static func automationTimedOut(_ name: String, _ seconds: Int) -> String {
        t("“\(name)” is still running after \(seconds) s; it keeps running.",
          "«\(name)» выполняется дольше \(seconds) с и продолжает работать.")
    }
    static func automationDaemonUp(_ name: String) -> String {
        t("“\(name)” is running in the background.", "«\(name)» работает в фоне.")
    }
    static func automationRunning(_ name: String) -> String {
        t("“\(name)” is running.", "«\(name)» выполняется.")
    }
    static func automationStopped(_ name: String) -> String {
        t("“\(name)” was stopped.", "«\(name)» остановлена.")
    }
    static func automationStopPending(_ name: String) -> String {
        t("Stop of “\(name)” was requested, but it is still running.",
          "Остановка «\(name)» запрошена, но она ещё работает.")
    }
    static func automationAlreadyRunning(_ name: String) -> String {
        t("“\(name)” is already running; it was not started again.",
          "«\(name)» уже запущена; повторный запуск не выполнен.")
    }
    static func automationOpenedInTerminal(_ name: String) -> String {
        t("“\(name)” was opened in the terminal; its result is shown there.",
          "«\(name)» открыта в терминале; результат — там.")
    }
    static func automationNotRunning(_ name: String) -> String {
        t("“\(name)” is not running.", "«\(name)» не запущена.")
    }
}
