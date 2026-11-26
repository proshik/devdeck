import Foundation

/// Strings for Shortcuts automation (stage 8): the settings switch, the per-item flag,
/// refusals and the `message` line of an action's result.
extension L10n {
    static var automationSection: String { t("Automation", "Автоматизация") }
    static var automationToggle: String { t("Accept requests from Shortcuts", "Принимать запросы из Shortcuts") }
    static var automationHelp: String {
        t("Shortcuts, the `DevDeck automation` command line and coding agents can run, stop and read only the commands and chains marked “Allow from Shortcuts”. Proxy selection, the proxy share and keep-awake need their own switch as well. Arbitrary shell commands are never accepted. Usage: /Applications/DevDeck.app/Contents/MacOS/DevDeck automation help",
          "Shortcuts, командная строка `DevDeck automation` и coding agents могут запускать, останавливать и опрашивать только команды и цепочки с флажком «Разрешить из Shortcuts». Выбору и раздаче прокси и режиму «без сна» нужен ещё и свой переключатель. Произвольные shell-команды не принимаются. Справка: /Applications/DevDeck.app/Contents/MacOS/DevDeck automation help")
    }
    static var automationProxyToggle: String {
        t("Proxy from the command line", "Прокси из командной строки")
    }
    static var automationAwakeToggle: String {
        t("Keep-awake from the command line", "«Без сна» из командной строки")
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
        t("Unknown operation “\(value)”: expected list, run, stop, status, brightness, proxy or awake.",
          "Неизвестная операция «\(value)»: нужна list, run, stop, status, brightness, proxy или awake.")
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

    // MARK: command line — brightness

    static var automationUsageNoBrightnessAction: String {
        t("No brightness action given: expected list, get, set, up or down.",
          "Не указано действие яркости: нужно list, get, set, up или down.")
    }
    static func automationUsageUnknownBrightnessAction(_ value: String) -> String {
        t("Unknown brightness action “\(value)”: expected list, get, set, up or down.",
          "Неизвестное действие яркости «\(value)»: нужно list, get, set, up или down.")
    }
    static var automationUsageMissingBrightness: String {
        t("set needs a brightness from 0 to 100.", "set нужна яркость от 0 до 100.")
    }
    static func automationUsageBadBrightness(_ value: String) -> String {
        t("Brightness is a percentage from 0 to 100, got “\(value)”.",
          "Яркость — процент от 0 до 100, получено «\(value)».")
    }
    static func automationUsageBadBrightnessStep(_ value: String) -> String {
        t("The step is a percentage above 0 and up to 100, got “\(value)”.",
          "Шаг — процент больше 0 и не больше 100, получено «\(value)».")
    }
    static var automationUsageBrightnessListDisplay: String {
        t("list shows every display; --display is for get, set, up and down.",
          "list показывает все экраны; --display — для get, set, up и down.")
    }
    private static func displayList(_ displays: [String]) -> String {
        t("Displays (name, id, available):\n", "Экраны (имя, id, доступность):\n") + displays.joined(separator: "\n")
    }
    static var automationNoBrightnessDisplays: String {
        t("DevDeck sees no displays right now.", "DevDeck сейчас не видит ни одного экрана.")
    }
    static func automationNoPointerDisplay(_ displays: [String]) -> String {
        t("The pointer is over no display, so there is no brightness-key target. Pass --display.\n",
          "Курсор не над экраном — цели клавиш яркости нет. Укажите --display.\n") + displayList(displays)
    }
    static func automationDisplayUnsupported(_ name: String, _ displays: [String]) -> String {
        t("“\(name)” has no brightness control in DevDeck.\n", "У экрана «\(name)» нет управления яркостью в DevDeck.\n")
            + displayList(displays)
    }
    static func automationUnknownDisplay(_ query: String, _ displays: [String]) -> String {
        t("There is no display named or with the id “\(query)”.\n", "Экрана с именем или id «\(query)» нет.\n")
            + displayList(displays)
    }
    static func automationAmbiguousDisplay(_ query: String, _ displays: [String]) -> String {
        t("Several displays are named “\(query)”; pass one of these ids instead.\n",
          "Несколько экранов называются «\(query)»; укажите вместо имени один из id.\n") + displayList(displays)
    }
    static func automationBrightnessApplied(_ name: String, _ level: String) -> String {
        t("\(name): \(level)", "\(name): \(level)")
    }
    static func automationBrightnessAtLimit(_ name: String, _ level: String) -> String {
        t("\(name) is already at \(level).", "\(name) уже на \(level).")
    }
    static func automationBrightnessUnconfirmed(_ name: String, _ level: String) -> String {
        t("\(name) did not confirm the change; it reads back \(level).",
          "\(name) не подтвердил изменение; читается \(level).")
    }
    static func automationBrightnessReplaced(_ name: String) -> String {
        t("The change to \(name) was not applied: a newer change replaced it or the displays changed.",
          "Изменение для \(name) не применено: его заменило более новое или сменились экраны.")
    }
    static func automationBrightnessTimedOut(_ name: String, _ seconds: Int) -> String {
        t("\(name) did not confirm the change within \(seconds) s; the write may still finish.",
          "\(name) не подтвердил изменение за \(seconds) с; запись может ещё завершиться.")
    }

    // MARK: command line — proxy

    static var automationProxyDisabled: String {
        t("Proxy automation is turned off: turn on “Proxy from the command line” in Settings → Automation.",
          "Прокси из командной строки выключены: включите «Прокси из командной строки» в Настройки → Автоматизация.")
    }
    private static func proxyList(_ proxies: [String]) -> String {
        proxies.isEmpty ? "" : t("\nProxies (type, name, id):\n", "\nПрокси (тип, имя, id):\n") + proxies.joined(separator: "\n")
    }
    static func automationUnknownProxy(_ query: String, _ proxies: [String], discoveryOn: Bool) -> String {
        t("There is no proxy named or with the id “\(query)”.", "Прокси с именем или id «\(query)» нет.")
            + (discoveryOn ? "" : t(" LAN discovery is off, so LAN proxies are not listed.",
                                    " Поиск в сети выключен, поэтому LAN-прокси не видны."))
            + proxyList(proxies)
    }
    static func automationAmbiguousProxy(_ query: String, _ proxies: [String]) -> String {
        t("Several proxies are named “\(query)”; pass a remote proxy's UUID or rename one in DevDeck.",
          "Несколько прокси называются «\(query)»; укажите UUID удалённого прокси или переименуйте один в DevDeck.")
            + proxyList(proxies)
    }
    static func automationProxyCredentialsMissing(_ name: String) -> String {
        t("“\(name)” needs a username and password, and none are saved for it. Choose it on the Proxy page in DevDeck and enter them there; the command line never takes passwords.",
          "«\(name)» требует имя пользователя и пароль, а сохранённых нет. Выберите его на странице «Прокси» в DevDeck и введите их там; командная строка пароли не принимает.")
    }
    static func automationRemoteTunnelMissing(_ name: String) -> String {
        t("Remote proxy “\(name)” has no tunnel command; fix it on the Proxy page.",
          "У удалённого прокси «\(name)» нет команды туннеля; исправьте это на странице «Прокси».")
    }
    static var automationSharePasswordMissing: String {
        t("Sharing with a password needs the share password saved in DevDeck: set it on the Proxy page; the command line never takes passwords.",
          "Для раздачи с паролем нужен сохранённый в DevDeck пароль раздачи: задайте его на странице «Прокси»; командная строка пароли не принимает.")
    }
    static var automationShareUsernameMissing: String {
        t("Sharing with a password needs a username: pass --username or set it on the Proxy page.",
          "Для раздачи с паролем нужно имя пользователя: передайте --username или задайте его на странице «Прокси».")
    }
    static func automationProxyListEmpty(discoveryOn: Bool) -> String {
        discoveryOn
            ? t("No proxies: none is announced on the LAN and no remote proxy is set up.",
                "Прокси нет: в сети никто не объявлен, удалённые прокси не настроены.")
            : t("No proxies: LAN discovery is off and no remote proxy is set up.",
                "Прокси нет: поиск в сети выключен, удалённые прокси не настроены.")
    }
    static func automationProxyUsable(_ name: String) -> String {
        t("Commands that go through a proxy use “\(name)”.", "Команды через прокси идут через «\(name)».")
    }
    static func automationProxyNotUsable(_ name: String) -> String {
        t("“\(name)” is chosen but not usable right now; commands that go through a proxy will not start.",
          "«\(name)» выбран, но сейчас недоступен; команды через прокси не запустятся.")
    }
    static var automationProxyNone: String {
        t("No proxy is chosen; commands that go through a proxy will not start.",
          "Прокси не выбран; команды через прокси не запустятся.")
    }
    static var automationProxyCleared: String {
        t("The proxy selection was cleared.", "Выбор прокси снят.")
    }
    static var automationProxySelectionChanged: String {
        t("The proxy selection changed meanwhile.", "Выбор прокси тем временем изменился.")
    }
    static func automationRemotePortOccupied(_ name: String, _ port: Int, _ process: String, _ pid: Int32) -> String {
        t("“\(name)” is chosen, but port \(port) is occupied by \(process) (PID \(pid)); free it or resolve it in DevDeck.",
          "«\(name)» выбран, но порт \(port) занят процессом \(process) (PID \(pid)); освободите его или решите в DevDeck.")
    }
    static func automationRemoteFailed(_ name: String) -> String {
        t("“\(name)” is chosen, but its tunnel or bridge stopped; the watchdog may retry. See the output below.",
          "«\(name)» выбран, но его туннель или мост остановился; watchdog может перезапустить. Вывод — ниже.")
    }
    static func automationRemoteTimedOut(_ name: String, _ seconds: Int) -> String {
        t("“\(name)” is chosen; its tunnel and bridge are not both up after \(seconds) s and keep starting.",
          "«\(name)» выбран; туннель и мост за \(seconds) с не поднялись оба и продолжают запускаться.")
    }
    static func automationProxyCheckOK(_ name: String, _ ip: String) -> String {
        t("Traffic through “\(name)” leaves from \(ip).", "Трафик через «\(name)» выходит с \(ip).")
    }
    static func automationProxyCheckFailed(_ name: String) -> String {
        t("The check through “\(name)” got no answer.", "Проверка через «\(name)» не получила ответа.")
    }
    static func automationProxyCheckTimedOut(_ seconds: Int) -> String {
        t("The check got no result within \(seconds) s.", "Проверка не дала результата за \(seconds) с.")
    }
    static func automationSharePortOccupied(_ port: Int, _ process: String, _ pid: Int32) -> String {
        t("The share is not running: port \(port) is occupied by \(process) (PID \(pid)).",
          "Раздача не работает: порт \(port) занят процессом \(process) (PID \(pid)).")
    }
    static func automationShareUp(_ port: Int) -> String {
        t("This Mac shares its connection on port \(port).", "Этот Mac раздаёт соединение на порту \(port).")
    }
    static func automationShareAlreadyOn(_ port: Int) -> String {
        t("The share is already running on port \(port).", "Раздача уже работает на порту \(port).")
    }
    static var automationShareStarting: String { t("The share is starting.", "Раздача запускается.") }
    static func automationShareFailed(_ code: Int32) -> String {
        t("The share listener stopped with exit code \(code).", "Listener раздачи остановился, код \(code).")
    }
    static var automationShareNotRunning: String {
        t("The share is on but its listener is not running.", "Раздача включена, но listener не работает.")
    }
    static var automationShareOff: String { t("The share is off.", "Раздача выключена.") }
    static var automationShareStopPending: String {
        t("The share was turned off, but its listener is still stopping.",
          "Раздача выключена, но listener ещё останавливается.")
    }
    static var automationShareUnchanged: String {
        t("The share settings already have these values; nothing changed.",
          "Настройки раздачи уже такие; ничего не изменилось.")
    }
    static var automationShareSaved: String { t("The share settings were saved.", "Настройки раздачи сохранены.") }
    static var automationShareNotStarted: String {
        t("The share listener was not started; the DevDeck diagnostic log says why.",
          "Listener раздачи не запущен; причина — в диагностическом журнале DevDeck.")
    }
    static func automationShareTimedOut(_ seconds: Int) -> String {
        t("The share listener is not up after \(seconds) s and keeps starting.",
          "Listener раздачи не поднялся за \(seconds) с и продолжает запускаться.")
    }

    static var automationUsageNoProxyAction: String {
        t("No proxy action given: expected list, status, use, check or share.",
          "Не указано действие прокси: нужно list, status, use, check или share.")
    }
    static func automationUsageUnknownProxyAction(_ value: String) -> String {
        t("Unknown proxy action “\(value)”: expected list, status, use, check or share.",
          "Неизвестное действие прокси «\(value)»: нужно list, status, use, check или share.")
    }
    static var automationUsageMissingProxy: String {
        t("use needs a proxy name, a remote proxy's UUID or none.",
          "use нужно имя прокси, UUID удалённого прокси или none.")
    }
    static var automationUsageNoShareAction: String {
        t("No share action given: expected on, off, status or set.",
          "Не указано действие раздачи: нужно on, off, status или set.")
    }
    static func automationUsageUnknownShareAction(_ value: String) -> String {
        t("Unknown share action “\(value)”: expected on, off, status or set.",
          "Неизвестное действие раздачи «\(value)»: нужно on, off, status или set.")
    }
    static func automationUsageBadPort(_ value: String) -> String {
        t("--port takes a whole number from 1 to 65535, got “\(value)”.",
          "--port — целое число от 1 до 65535, получено «\(value)».")
    }
    static func automationUsageBadEngine(_ value: String) -> String {
        t("--engine takes builtIn or gost, got “\(value)”.", "--engine — builtIn или gost, получено «\(value)».")
    }
    static func automationUsageBadAuth(_ value: String) -> String {
        t("--auth takes on or off, got “\(value)”.", "--auth — on или off, получено «\(value)».")
    }
    static var automationUsageBadUsername: String {
        t("A share username cannot contain “:” — proxy logins split at the first colon.",
          "Имя пользователя раздачи не может содержать «:» — логин прокси делится по первому двоеточию.")
    }
    static var automationRemoteStopPending: String {
        t("The choice changed, but the previous tunnel or bridge is still stopping.",
          "Выбор изменён, но прежний туннель или мост ещё останавливается.")
    }
    static var automationAwakeReplaced: String {
        t("This keep-awake request was replaced by another start; check awake status.",
          "Этот запрос «без сна» заменил другой запуск; смотрите awake status.")
    }
    static var automationUsageNoShareField: String {
        t("share set needs at least one of --port, --engine, --service-name, --auth, --username.",
          "share set нужен хотя бы один из --port, --engine, --service-name, --auth, --username.")
    }

    // MARK: command line — keep-awake

    static var automationAwakeDisabled: String {
        t("Keep-awake automation is turned off: turn on “Keep-awake from the command line” in Settings → Automation.",
          "«Без сна» из командной строки выключено: включите «„Без сна“ из командной строки» в Настройки → Автоматизация.")
    }
    static var automationAwakeRecovering: String {
        t("Sleep is being restored right now; this cannot be interrupted. Try again in a moment.",
          "Сейчас восстанавливается сон; это не прерывается. Повторите чуть позже.")
    }
    static var automationAwakeAlreadyOn: String {
        t("Sleep is already disabled; the running session is kept.",
          "Сон уже отключён; текущая сессия сохранена.")
    }
    static func automationAwakeAuthorizationPending(_ seconds: Int) -> String {
        t("No administrator approval within \(seconds) s. The request stays open: sleep is disabled once it is approved.",
          "За \(seconds) с подтверждения администратора нет. Запрос остаётся открытым: сон отключится, когда его подтвердят.")
    }
    static var automationAwakeCancelled: String {
        t("Administrator approval was cancelled; sleep was not disabled.",
          "Подтверждение администратора отменено; сон не отключён.")
    }
    static var automationAwakeStopped: String { t("Sleep was restored.", "Сон восстановлен.") }
    static func automationAwakeOnFor(_ remaining: String) -> String {
        t("Sleep is disabled for another \(remaining).", "Сон отключён ещё на \(remaining).")
    }
    static var automationAwakeOnIndefinitely: String {
        t("Sleep is disabled with no timer.", "Сон отключён без таймера.")
    }
    static func automationConfigNotSaved(_ detail: String) -> String {
        t("DevDeck cannot save config.json right now, so nothing was changed: \(detail)",
          "DevDeck сейчас не может сохранить config.json, поэтому ничего не изменено: \(detail)")
    }
    static var automationShareSuperseded: String {
        t("Another change of the share settings replaced this one while the listener was restarting.",
          "Пока listener перезапускался, эти настройки раздачи заменило другое изменение.")
    }
    static var automationAwakeOff: String { t("Keep-awake is off.", "«Без сна» выключено.") }

    static var automationUsageNoAwakeAction: String {
        t("No keep-awake action given: expected on, off or status.",
          "Не указано действие «без сна»: нужно on, off или status.")
    }
    static func automationUsageUnknownAwakeAction(_ value: String) -> String {
        t("Unknown keep-awake action “\(value)”: expected on, off or status.",
          "Неизвестное действие «без сна» «\(value)»: нужно on, off или status.")
    }
    static var automationUsageForOnlyOn: String {
        t("--for is only for awake on.", "--for — только для awake on.")
    }
    static func automationUsageBadDuration(_ value: String) -> String {
        t("--for takes 0 (no timer), seconds or 30m, 2h, 1h30m, 90s — up to 2h; got “\(value)”.",
          "--for — 0 (без таймера), секунды или 30m, 2h, 1h30m, 90s — не больше 2h; получено «\(value)».")
    }

    static var automationHelpText: String {
        let path = "/Applications/DevDeck.app/Contents/MacOS/DevDeck"
        let codes = """
             \(AutomationExitCode.success)  succeeded, daemon up, alreadyRunning, openedInTerminal, stopped, status, list; proxy chosen/up, check ok; sleep disabled/restored
             \(AutomationExitCode.failed)  failed (including a cancelled sudo prompt); brightness not confirmed by the display; tunnel, bridge or share down; check failed; keep-awake not approved
             \(AutomationExitCode.timedOut)  timedOut — still running when the wait ran out (it keeps running); no brightness readback in \(AutomationLimits.brightnessWaitSeconds) s; proxy or keep-awake still starting
             \(AutomationExitCode.refused)  refused — automation off, not allowed, unknown or ambiguous name or display, port, proxy, credentials needed…
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
              \(path) automation brightness list
              \(path) automation brightness get [--display <name|id>]
              \(path) automation brightness set <0…100> [--display <name|id>]
              \(path) automation brightness up|down [STEP] [--display <name|id>]
              \(path) automation proxy list | status | check
              \(path) automation proxy use <name|UUID|none>
              \(path) automation proxy share on|off|status
              \(path) automation proxy share set [--port N] [--engine builtIn|gost] [--service-name S] [--auth on|off] [--username U]
              \(path) automation awake on [--for 0|SECONDS|30m|2h|1h30m]
              \(path) automation awake off | status
              \(path) automation help

            A name must match exactly (quote it if it has spaces); a UUID may be in any case.
            run waits for a one-shot command or a chain up to --timeout (default \(AutomationLimits.defaultTimeoutSeconds) s,
            \(AutomationLimits.minTimeoutSeconds)…\(AutomationLimits.maxTimeoutSeconds)); a daemon until it is up. --directory is for commands that ask
            for a directory on every run; a relative path is taken from the current directory.
            DevDeck must be running — this command does not start it. A development build uses the
            data directory packaged into it, or --dev-data-directory PATH like the running dev app.

            Brightness works like the brightness keys and the slider: the same scale, 0 is a black
            cover, the display must read the level back, the OSD shows it. Without --display it is
            the display under the pointer (with the linked ones if the keys are on and linked);
            --display takes an exact name or id from brightness list and changes only that display.
            up/down without STEP is one key press; STEP is in percent. Each display is a block of
            key: value lines (status applied|atLimit|failed|timedOut, display, id, method
            ddc|native|software|none, available, brightness, approxNits, confirmed, message).

            proxy and awake also need their own switch in Settings → Automation. proxy use picks a LAN
            proxy by its exact name or a remote (VDS) proxy by name or UUID, exactly like the popover:
            a remote one starts its ssh tunnel and bridge (the answer waits up to \(AutomationLimits.proxyStartWaitSeconds) s), choosing a
            LAN one stops them; none clears the choice. Passwords are never accepted: a LAN proxy
            without saved credentials and --auth on without a saved share password are refused —
            enter them on the Proxy page. The username is kept only for the current choice, so after
            switching away choose that proxy again in DevDeck. Remote proxies are added and edited
            only in DevDeck.
            proxy check probes the chosen proxy and prints the exit IP; "up" elsewhere means the
            daemons run, as in the popover, and only check proves the route. share set saves the share and
            restarts it if it is running, like Save on the Proxy page. awake on disables sleep after
            administrator approval (Touch ID or password; the answer waits up to \(AutomationLimits.awakeStartWaitSeconds) s): --for is up to 2h,
            0 means no timer (quitting DevDeck, 20% battery or heat still end it), without --for the
            duration chosen in DevDeck. Each proxy, the
            share and keep-awake are blocks of key: value lines (proxy list: name, type lan|remote,
            id, live, auth, active, endpoint; awake: status on|off|starting|stopping|recovering|failed,
            durationSeconds, remainingSeconds, message).

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
              \(path) automation brightness list
              \(path) automation brightness get [--display <имя|id>]
              \(path) automation brightness set <0…100> [--display <имя|id>]
              \(path) automation brightness up|down [ШАГ] [--display <имя|id>]
              \(path) automation proxy list | status | check
              \(path) automation proxy use <имя|UUID|none>
              \(path) automation proxy share on|off|status
              \(path) automation proxy share set [--port N] [--engine builtIn|gost] [--service-name S] [--auth on|off] [--username U]
              \(path) automation awake on [--for 0|СЕКУНДЫ|30m|2h|1h30m]
              \(path) automation awake off | status
              \(path) automation help

            Имя — точное совпадение (с пробелами — в кавычках); UUID — в любом регистре.
            run ждёт разовую команду или цепочку до --timeout (по умолчанию \(AutomationLimits.defaultTimeoutSeconds) с,
            \(AutomationLimits.minTimeoutSeconds)…\(AutomationLimits.maxTimeoutSeconds)); daemon — пока не поднимется. --directory — для команд, которые
            спрашивают каталог при каждом запуске; относительный путь берётся от текущего каталога.
            DevDeck должен быть запущен — эта команда его не запускает. Dev-сборка берёт каталог
            данных, упакованный в неё, или --dev-data-directory PATH, как у запущенной dev-app.

            Яркость работает как клавиши яркости и ползунок: та же шкала, 0 — чёрная накладка, экран
            должен подтвердить уровень, показывается OSD. Без --display — экран под курсором (со
            связанными, если клавиши включены и связаны); --display — точное имя или id из brightness
            list, меняется только этот экран. up/down без ШАГА — одно нажатие клавиши; ШАГ в процентах.
            Каждый экран — блок строк key: value (status applied|atLimit|failed|timedOut, display, id,
            method ddc|native|software|none, available, brightness, approxNits, confirmed, message).

            proxy и awake требуют ещё и своего переключателя в Настройки → Автоматизация. proxy use
            выбирает LAN-прокси по точному имени или удалённый (VDS) по имени или UUID — так же, как
            панель: для удалённого поднимаются ssh-туннель и мост (ответ ждёт до \(AutomationLimits.proxyStartWaitSeconds) с), выбор
            LAN-прокси их гасит; none снимает выбор. Пароли не принимаются: LAN-прокси без сохранённых
            учётных данных и --auth on без сохранённого пароля раздачи — отказ, их вводят на странице
            «Прокси». Имя пользователя хранится только для текущего выбора: после переключения
            выберите такой прокси снова в DevDeck. Удалённые прокси добавляются и меняются только в DevDeck. proxy check проверяет
            выбранный прокси и печатает exit IP; «поднялся» в остальных ответах значит «демоны работают»,
            как в панели, а маршрут доказывает только check. share set сохраняет раздачу и перезапускает её, если
            она работает, как «Сохранить» на странице «Прокси». awake on отключает сон после
            подтверждения администратора (Touch ID или пароль; ответ ждёт до \(AutomationLimits.awakeStartWaitSeconds) с): --for до 2h,
            0 — без таймера (выход из DevDeck, 20% заряда или перегрев всё равно завершают), без --for —
            длительность, выбранная в DevDeck. Каждый прокси, раздача
            и «без сна» — блоки строк key: value (proxy list: name, type lan|remote, id, live, auth,
            active, endpoint; awake: status on|off|starting|stopping|recovering|failed,
            durationSeconds, remainingSeconds, message).

            Вывод: строки key: value в stdout, ошибки — в stderr; list печатает тип<TAB>UUID<TAB>имя.

            Коды выхода:
            \(codes)
            """)
    }
}
