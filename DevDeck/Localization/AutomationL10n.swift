import Foundation

/// Strings for Shortcuts automation (stage 8): the settings switch, the per-item flag,
/// refusals and the `message` line of an action's result.
extension L10n {
    static var automationSection: String { t("Automation", "Автоматизация") }
    static var automationToggle: String { t("Accept requests from Shortcuts", "Принимать запросы из Shortcuts") }
    static var automationHelp: String {
        t("Shortcuts, the `DevDeck automation` command line and coding agents can run, stop and read only the commands and chains marked “Allow from Shortcuts”. Arbitrary shell commands are never accepted. Usage: /Applications/DevDeck.app/Contents/MacOS/DevDeck automation help",
          "Shortcuts, командная строка `DevDeck automation` и coding agents могут запускать, останавливать и опрашивать только команды и цепочки с флажком «Разрешить из Shortcuts». Произвольные shell-команды не принимаются. Справка: /Applications/DevDeck.app/Contents/MacOS/DevDeck automation help")
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

    // MARK: command line (`DevDeck automation …`)

    static func automationUnknownName(_ chain: Bool, _ name: String) -> String {
        chain
            ? t("There is no DevDeck chain named “\(name)”. `DevDeck automation list` shows the allowed ones.",
                "Цепочки DevDeck с именем «\(name)» нет. Разрешённые показывает `DevDeck automation list`.")
            : t("There is no DevDeck command named “\(name)”. `DevDeck automation list` shows the allowed ones.",
                "Команды DevDeck с именем «\(name)» нет. Разрешённые показывает `DevDeck automation list`.")
    }
    static func automationAmbiguousName(_ chain: Bool, _ name: String, _ ids: [UUID]) -> String {
        let list = ids.map(\.uuidString).joined(separator: "\n")
        return chain
            ? t("Several DevDeck chains are named “\(name)”; pass one of these UUIDs instead:\n\(list)",
                "Несколько цепочек DevDeck называются «\(name)»; укажите вместо имени один из UUID:\n\(list)")
            : t("Several DevDeck commands are named “\(name)”; pass one of these UUIDs instead:\n\(list)",
                "Несколько команд DevDeck называются «\(name)»; укажите вместо имени один из UUID:\n\(list)")
    }
    static var automationListEmpty: String {
        t("No commands or chains are allowed from Shortcuts. Turn on “Allow from Shortcuts” in an editor.",
          "Нет команд и цепочек, разрешённых из Shortcuts. Включите «Разрешить из Shortcuts» в редакторе.")
    }
    static var automationBadRequest: String {
        t("DevDeck could not read the request.", "DevDeck не смог прочитать запрос.")
    }
    static func automationVersionMismatch(_ version: Int) -> String {
        t("This DevDeck speaks automation protocol \(AutomationRequest.currentVersion), the request uses \(version). Use the DevDeck binary of the running app.",
          "Этот DevDeck понимает протокол автоматизации \(AutomationRequest.currentVersion), а запрос — \(version). Вызывайте исполняемый файл запущенного DevDeck.")
    }
    static var automationIncompleteRequest: String {
        t("The request names no command or chain.", "В запросе не указана команда или цепочка.")
    }
    static var automationAppNotRunning: String {
        t("DevDeck is not running (for this build and data directory). Start it and try again; the command line does not launch it.",
          "DevDeck не запущен (для этой сборки и каталога данных). Запустите его и повторите; командная строка его не запускает.")
    }
    static func automationCommunicationFailed(_ detail: String) -> String {
        t("Could not talk to DevDeck: \(detail)", "Не удалось связаться с DevDeck: \(detail)")
    }
    static func automationNoAnswer(_ seconds: Int) -> String {
        t("no answer within \(seconds) s", "нет ответа за \(seconds) с")
    }
    static func automationUsage(_ problem: String) -> String {
        t("\(problem)\nRun `DevDeck automation help` for usage.",
          "\(problem)\nСправка: `DevDeck automation help`.")
    }
    static var automationUsageNoOperation: String { t("No operation given.", "Не указана операция.") }
    static func automationUsageUnknownOperation(_ value: String) -> String {
        t("Unknown operation “\(value)”: expected list, run, stop or status.",
          "Неизвестная операция «\(value)»: нужна list, run, stop или status.")
    }
    static func automationUsageUnknownKind(_ value: String) -> String {
        t("Unknown kind “\(value)”: expected command or chain.", "Неизвестный тип «\(value)»: нужен command или chain.")
    }
    static var automationUsageMissingTarget: String {
        t("Name or UUID of the command or chain is missing.", "Не указано имя или UUID команды либо цепочки.")
    }
    static func automationUsageExtraArgument(_ value: String) -> String {
        t("Unexpected argument “\(value)” (quote a name with spaces).",
          "Лишний аргумент «\(value)» (имя с пробелами возьмите в кавычки).")
    }
    static func automationUsageUnknownOption(_ value: String) -> String {
        t("Unknown option “\(value)”.", "Неизвестный параметр «\(value)».")
    }
    static func automationUsageMissingValue(_ option: String) -> String {
        t("Option \(option) needs a value.", "Параметру \(option) нужно значение.")
    }
    static func automationUsageBadTimeout(_ value: String) -> String {
        t("--timeout takes whole seconds from \(AutomationLimits.minTimeoutSeconds) to \(AutomationLimits.maxTimeoutSeconds), got “\(value)”.",
          "--timeout — целые секунды от \(AutomationLimits.minTimeoutSeconds) до \(AutomationLimits.maxTimeoutSeconds), получено «\(value)».")
    }
    static func automationUsageOptionNotApplicable(_ option: String) -> String {
        t("Option \(option) does not apply here: --directory is for run command, --timeout for run.",
          "Параметр \(option) здесь неприменим: --directory — только для run command, --timeout — для run.")
    }

    static var automationHelpText: String {
        let path = "/Applications/DevDeck.app/Contents/MacOS/DevDeck"
        let codes = """
             \(AutomationExitCode.success)  succeeded, daemon up, alreadyRunning, openedInTerminal, stopped, status, list
             \(AutomationExitCode.failed)  failed (including a cancelled sudo prompt)
             \(AutomationExitCode.timedOut)  timedOut — still running when the wait ran out (it keeps running)
             \(AutomationExitCode.refused)  refused — automation off, not allowed, unknown or ambiguous name, port, proxy…
             \(AutomationExitCode.appNotRunning)  DevDeck is not running
             \(AutomationExitCode.communication)  could not talk to DevDeck
             \(AutomationExitCode.usage) usage error
            """
        return t("""
            Run, stop and read saved DevDeck commands and chains from a terminal, a coding agent or
            Shortcuts (“Run Shell Script”). Only items marked “Allow from Shortcuts” are reachable,
            and only while Settings → Automation is on. Shell strings are never accepted.

            Usage:
              \(path) automation list
              \(path) automation run command <name|UUID> [--directory PATH] [--timeout SECONDS]
              \(path) automation run chain <name|UUID> [--timeout SECONDS]
              \(path) automation stop command|chain <name|UUID>
              \(path) automation status command|chain <name|UUID>
              \(path) automation help

            A name must match exactly (quote it if it has spaces); a UUID may be in any case.
            run waits for a one-shot command or a chain up to --timeout (default \(AutomationLimits.defaultTimeoutSeconds) s,
            \(AutomationLimits.minTimeoutSeconds)…\(AutomationLimits.maxTimeoutSeconds)); a daemon until it is up. --directory is for commands that ask
            for a directory on every run; a relative path is taken from the current directory.
            DevDeck must be running — this command does not start it. A development build uses the
            data directory packaged into it, or --dev-data-directory PATH like the running dev app.

            Output: key: value lines on stdout, errors on stderr; list prints kind<TAB>UUID<TAB>name.

            Exit codes:
            \(codes)
            """, """
            Запуск, остановка и состояние сохранённых команд и цепочек DevDeck из терминала, coding agent
            или Shortcuts («Run Shell Script»). Доступны только элементы с флажком «Разрешить из Shortcuts»
            и только при включённой «Настройки → Автоматизация». Shell-строки не принимаются.

            Использование:
              \(path) automation list
              \(path) automation run command <имя|UUID> [--directory PATH] [--timeout SECONDS]
              \(path) automation run chain <имя|UUID> [--timeout SECONDS]
              \(path) automation stop command|chain <имя|UUID>
              \(path) automation status command|chain <имя|UUID>
              \(path) automation help

            Имя — точное совпадение (с пробелами — в кавычках); UUID — в любом регистре.
            run ждёт разовую команду или цепочку до --timeout (по умолчанию \(AutomationLimits.defaultTimeoutSeconds) с,
            \(AutomationLimits.minTimeoutSeconds)…\(AutomationLimits.maxTimeoutSeconds)); daemon — пока не поднимется. --directory — для команд, которые
            спрашивают каталог при каждом запуске; относительный путь берётся от текущего каталога.
            DevDeck должен быть запущен — эта команда его не запускает. Dev-сборка берёт каталог
            данных, упакованный в неё, или --dev-data-directory PATH, как у запущенной dev-app.

            Вывод: строки key: value в stdout, ошибки — в stderr; list печатает тип<TAB>UUID<TAB>имя.

            Коды выхода:
            \(codes)
            """)
    }
}
