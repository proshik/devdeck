import Foundation

/// Central catalog of every user-facing string, in English and Russian.
///
/// One namespace, one place to translate. Each entry resolves to the current
/// language via `t(_:_:)`. Call sites read these (e.g. `Text(L10n.commands)`),
/// so switching language in Settings updates the whole UI live.
enum L10n {

    // MARK: - Sections (popover & main window)

    static var commands: String { t("Commands", "Команды") }
    static var daemons: String { t("Daemons", "Демоны") }
    static var chains: String { t("Chains", "Цепочки") }

    // MARK: - Popover

    static var noCommandsYet: String { t("No commands yet", "Команд пока нет") }
    static var memory: String { t("Memory", "Память") }
    static var swap: String { t("Swap", "Своп") }
    static var openDevDeck: String { t("Open DevDeck…", "Открыть DevDeck…") }
    static var revealLogHelp: String { t("Reveal devdeck.log in Finder", "Показать devdeck.log в Finder") }
    static var quit: String { t("Quit", "Выход") }
    static var run: String { t("Run", "Запустить") }
    static var stop: String { t("Stop", "Остановить") }
    static var logs: String { t("Logs", "Логи") }

    static var quitConfirmTitle: String { t("Quit DevDeck?", "Выйти из DevDeck?") }
    static var quitConfirmMessage: String {
        t("The app will quit completely — its menu bar icon will disappear.",
          "Приложение закроется полностью — иконка из строки меню исчезнет.")
    }
    static var quitButton: String { t("Quit", "Выйти") }
    static var cancel: String { t("Cancel", "Отмена") }

    // MARK: - Exit dialog (live daemons)

    static func exitDaemonsActive(_ count: Int) -> String {
        t("Active background daemons: \(count)", "Активны фоновые демоны: \(count)")
    }
    static var exitDaemonsQuestion: String {
        t("What should happen to the background processes (e.g. kubectl port-forward) before quitting?",
          "Что сделать с фоновыми процессами (например kubectl port-forward) перед выходом?")
    }
    static var exitKill: String { t("Kill", "Убить") }
    static var exitKeepInBackground: String { t("Keep in background", "Оставить в фоне") }

    // MARK: - Main window

    static var untitled: String { t("(untitled)", "(без имени)") }
    static var settings: String { t("Settings", "Настройки") }
    static var newCommand: String { t("New command", "Новая команда") }
    static var newDaemon: String { t("New daemon", "Новый демон") }
    static var newChain: String { t("New chain", "Новая цепочка") }
    static var selectPlaceholder: String {
        t("Select a command or chain on the left, or create a new one (+)",
          "Выберите команду или цепочку слева, или создайте новую (+)")
    }
    static var commandTab: String { t("Command", "Команда") }
    static var chainTab: String { t("Chain", "Цепочка") }

    // MARK: - Command editor

    static var commandSection: String { t("Command", "Команда") }
    static var name: String { t("Name", "Имя") }
    static var commandFieldLabel: String { t("Command (zsh -lc)", "Команда (zsh -lc)") }
    static var workingDirectory: String { t("Working directory", "Рабочая директория") }
    static var choose: String { t("Choose…", "Выбрать…") }
    static var daemonToggle: String { t("Daemon (long-running)", "Демон (долгоживущий)") }
    static var needsSudoToggle: String { t("Requires sudo", "Требует sudo") }
    static var openInTerminalToggle: String { t("Open in terminal (Ghostty)", "Открывать в терминале (Ghostty)") }
    static var terminalModePicker: String { t("Terminal mode (shared)", "Режим терминала (общий)") }
    static var terminalWindow: String { t("New window", "Новое окно") }
    static var terminalTab: String { t("Tab (AppleScript)", "Таб (AppleScript)") }
    static var terminalCustom: String { t("Custom command", "Своя команда") }
    static var terminalCustomCommandLabel: String {
        t("Launch command (shared)", "Команда запуска (общая)")
    }
    static var terminalCustomCommandHint: String {
        t("{script} is replaced with the path to the generated script — already quoted, so don’t add quotes around it. Give the terminal by full path unless you know it is on the PATH of a login shell. Examples: /opt/homebrew/bin/wezterm start -- {script} · open -a iTerm {script} · kitty {script}",
          "{script} заменяется на путь к сгенерированному скрипту — уже в кавычках, свои кавычки добавлять не нужно. Указывайте терминал полным путём, если не уверены, что он есть в PATH логин-шелла. Примеры: /opt/homebrew/bin/wezterm start -- {script} · open -a iTerm {script} · kitty {script}")
    }
    static var keepTerminalOpenToggle: String {
        t("Stay in the shell after the command finishes", "Оставаться в шелле после завершения команды")
    }
    static var keepTerminalOpenHint: String {
        t("The tab becomes an ordinary shell in the same directory instead of closing — for re-running the command by hand or looking around afterwards.",
          "Таб превращается в обычный шелл в той же папке вместо закрытия — чтобы перезапустить команду руками или осмотреться после неё.")
    }

    static var envSection: String { t("Environment variables", "Переменные окружения") }
    static var envKeyPlaceholder: String { t("KEY", "КЛЮЧ") }
    static var envValuePlaceholder: String { t("value", "значение") }
    static var addEnvVar: String { t("Add variable", "Добавить переменную") }

    static var freeMemorySection: String { t("Free memory before launch", "Освободить память перед запуском") }
    static var noRunningApps: String { t("No running apps", "Нет запущенных приложений") }
    static var notRunning: String { t("(not running)", "(не запущено)") }
    static var refreshAppList: String { t("Refresh app list", "Обновить список приложений") }

    static var delete: String { t("Delete", "Удалить") }
    static var save: String { t("Save", "Сохранить") }
    static var saved: String { t("Saved", "Сохранено") }
    static var saveHelp: String { t("Save changes (⌘S)", "Сохранить изменения (⌘S)") }
    static var deleteCommandHelp: String { t("Delete command — asks for confirmation", "Удалить команду — спросит подтверждение") }
    static func deleteCommandTitle(_ name: String) -> String {
        t("Delete command “\(name)”?", "Удалить команду «\(name)»?")
    }
    static var deleteCommandMessage: String {
        t("The command disappears from the config and from all chains. This cannot be undone.",
          "Команда исчезнет из конфига и из всех цепочек. Действие необратимо.")
    }

    // MARK: - Chain editor

    static var chainSection: String { t("Chain", "Цепочка") }
    static var stopOnErrorToggle: String { t("Stop on error", "Останавливать при ошибке") }
    static var chainInOneTabToggle: String {
        t("Whole chain in one terminal tab (Ghostty)", "Вся цепочка в одном табе терминала (Ghostty)")
    }
    static var stepsSection: String {
        t("Steps (in order, drag to reorder)", "Шаги (по порядку, перетаскивайте для смены порядка)")
    }
    static var noSteps: String { t("No steps — add commands below", "Шагов нет — добавьте команды ниже") }
    static var deletedCommand: String { t("(deleted command)", "(удалённая команда)") }
    static var removeStep: String { t("Remove step", "Убрать шаг") }
    static var addStep: String { t("Add step", "Добавить шаг") }
    static var deleteChainHelp: String { t("Delete chain — asks for confirmation", "Удалить цепочку — спросит подтверждение") }
    static func deleteChainTitle(_ name: String) -> String {
        t("Delete chain “\(name)”?", "Удалить цепочку «\(name)»?")
    }
    static var deleteChainMessage: String {
        t("The step commands stay; only the chain is removed. This cannot be undone.",
          "Команды-шаги останутся, исчезнет только цепочка. Действие необратимо.")
    }

    // MARK: - Log view

    static var runningInGhostty: String { t("Running in Ghostty", "Выполняется в Ghostty") }
    static var ghosttyLogsNote: String {
        t("This command’s output goes to a separate Ghostty tab. No logs here.",
          "Вывод этой команды — в отдельном табе Ghostty. Здесь логов нет.")
    }
    static var logEmpty: String { t("Log is empty", "Лог пуст") }
    static var clear: String { t("Clear", "Очистить") }

    // MARK: - Settings

    static var memoryMonitoringSection: String { t("Memory monitoring", "Мониторинг памяти") }
    static var vmMonitoringToggle: String {
        t("Show VM memory (colima) and per-run peak", "Показывать память VM (colima) и пик за прогон")
    }
    static var minikubeMonitoringToggle: String {
        t("minikube memory from inside the VM (ssh probe) and OOM detection",
          "Память minikube изнутри VM (ssh-зонд) и OOM-детект")
    }
    static var languageSection: String { t("Language", "Язык") }
    static var appearanceSection: String { t("Appearance", "Внешний вид") }
    static var appearancePicker: String { t("Theme", "Тема") }
    static var appearanceSystem: String { t("System", "Системный") }
    static var appearanceLight: String { t("Light", "Светлый") }
    static var appearanceDark: String { t("Dark", "Тёмный") }
    static var updatesSection: String { t("Updates", "Обновления") }
    static var autoUpdateToggle: String {
        t("Automatically download and install updates", "Автоматически загружать и устанавливать обновления")
    }
    static var upToDate: String { t("DevDeck is up to date", "DevDeck обновлён") }
    static var checkForUpdates: String { t("Check now", "Проверить") }
    static func updateAvailableRow(_ current: String, _ latest: String, behind: Int) -> String {
        t("Update available: \(current) → \(latest) (\(behind) behind)",
          "Доступно обновление: \(current) → \(latest) (отстаёте на \(behind))")
    }
    static func updateAvailableHelp(_ latest: String) -> String {
        t("Update available: \(latest). Click to install.", "Доступно обновление: \(latest). Нажмите, чтобы установить.")
    }
    static var startupSection: String { t("Startup", "Запуск") }
    static var launchAtLoginToggle: String { t("Launch at login", "Запускать при входе") }
    static var globalHotkeyToggle: String { t("Global hotkey ⌃⌥D opens the deck", "Глобальный хоткей ⌃⌥D открывает деку") }
    static var languagePicker: String { t("Interface language", "Язык интерфейса") }

    // MARK: - Notifications

    static var notifDaemonStarted: String { t("Daemon started", "Демон запущен") }
    static var notifDaemonAdopted: String { t("Adopted daemon from previous session", "Перехвачен демон из прошлой сессии") }
    static var notifDaemonStopped: String { t("Daemon stopped", "Демон остановился") }
    static var notifDaemonFailedToStart: String { t("Daemon failed to start", "Демон не запустился") }
    static var notifCommandFailed: String { t("Command error", "Ошибка команды") }
    static var notifWatchdogGaveUp: String {
        t("Daemon keeps dying — auto-restart stopped", "Демон продолжает падать — авторестарт остановлен")
    }
    static func portStillOccupied(_ port: Int, _ name: String, _ pid: Int32) -> String {
        t("Port \(port) could not be freed: \(name) (PID \(pid)) is still listening",
          "Порт \(port) освободить не удалось: \(name) (PID \(pid)) всё ещё слушает")
    }

    // MARK: - Watchdog & port conflicts

    static var localPort: String { t("Local port", "Локальный порт") }
    static var portAutoDetectedHint: String {
        t("Enables the occupied-port check: if another process holds this port, DevDeck offers to kill it and start the daemon. For a port-forward enter the LOCAL port — the left one in the pair (30090:8080 → 30090), i.e. the port you open in the browser. Auto-filled when the command is edited.",
          "Нужен для проверки «порт занят»: если порт держит другой процесс, DevDeck предложит убить его и запустить демона. Для port-forward вводите ЛОКАЛЬНЫЙ порт — левый в паре (30090:8080 → 30090), то есть тот, что открываете в браузере. Подставляется автоматически при правке команды.")
    }
    static var watchdogToggle: String {
        t("Auto-restart if it dies (watchdog)", "Автоперезапуск при падении (watchdog)")
    }
    static var watchdogEnableHelp: String { t("Enable auto-restart (watchdog)", "Включить автоперезапуск (watchdog)") }
    static var watchdogDisableHelp: String { t("Disable auto-restart", "Выключить автоперезапуск") }
    static func watchdogRestartingHelp(_ attempt: Int) -> String {
        t("Restarting (attempt \(attempt))…", "Перезапуск (попытка \(attempt))…")
    }
    static var watchdogPausedHelp: String {
        t("Port is occupied — waiting for your decision", "Порт занят — ждёт вашего решения")
    }
    static var watchdogGaveUpHelp: String {
        t("Auto-restart gave up — the daemon keeps dying", "Автоперезапуск сдался — демон продолжает падать")
    }
    static var killAndStart: String { t("Kill & start", "Убить и запустить") }
    static func portOccupied(_ port: Int, _ name: String, _ pid: Int32) -> String {
        t("Port \(port) is occupied by \(name) (PID \(pid))", "Порт \(port) занят: \(name) (PID \(pid))")
    }
    static func notifNameCode(_ name: String, _ code: Int32) -> String {
        t("\(name) — code \(code)", "\(name) — код \(code)")
    }
    static func notifMemoryHigh(_ target: String) -> String {
        t("\(target) memory is running low", "\(target): память на исходе")
    }
    static var notifDiskFull: String {
        t("colima VM disk almost full", "Диск colima VM почти заполнен")
    }
    static var diskPruneAdvice: String {
        t("builds will slow down — run docker prune", "сборки замедлятся — рекомендуется docker prune")
    }

    // MARK: - Process manager (user-visible log lines)

    static var sudoDaemonUnsupported: String {
        t("sudo daemon is not supported: no managed stream/process",
          "sudo-демон не поддерживается: нет управляемого потока/процесса")
    }
    static func freeingMemoryClosing(_ apps: String) -> String {
        t("Freeing memory: quitting \(apps)…", "Освобождаю память: закрываю \(apps)…")
    }
    static func didNotClose(_ apps: String) -> String {
        t("Did not close (possibly unsaved): \(apps)", "Не закрылись (возможно несохранённое): \(apps)")
    }
    static func relaunchingApps(_ apps: String) -> String {
        t("Relaunching: \(apps)", "Возвращаю: \(apps)")
    }

    // MARK: - Config decode errors (shown in the popover banner)

    static func brokenJSON(_ detail: String) -> String {
        t("Broken JSON: \(detail)", "Битый JSON: \(detail)")
    }
    static func missingField(_ field: String, _ at: String) -> String {
        t("Missing required field “\(field)”\(at)", "Отсутствует обязательное поле «\(field)»\(at)")
    }
    static var atFileRoot: String { t("at the file root", "в корне файла") }
    static func atPath(_ path: String) -> String { t("at “\(path)”", "в «\(path)»") }
    static func wrongType(_ location: String, _ detail: String) -> String {
        t("Wrong type \(location): \(detail)", "Неверный тип \(location): \(detail)")
    }

    // MARK: - Terminal runner (user-visible)

    static var ghosttyNotFound: String {
        t("Ghostty not found (/Applications/Ghostty.app)", "Ghostty не найден (/Applications/Ghostty.app)")
    }
    static func terminalTabFailed(_ detail: String) -> String {
        t("Could not open a tab (does Ghostty need “Automation” access?): \(detail)",
          "Не удалось открыть таб (нужна «Автоматизация» для Ghostty?): \(detail)")
    }
    static func terminalLaunchFailed(_ detail: String) -> String {
        t("Could not launch in terminal: \(detail)", "Не удалось запустить в терминале: \(detail)")
    }
    static var terminalCustomCommandInvalid: String {
        t("The custom terminal command is empty or has no {script} placeholder — DevDeck wouldn’t know where to put the script.",
          "Своя команда терминала пуста или не содержит {script} — DevDeck негде подставить скрипт.")
    }
    static var terminalDidNotStart: String {
        t("Command did not start in the terminal — Ghostty did not open or Accessibility access for tabs is missing.",
          "Команда не стартовала в терминале — Ghostty не открылся или нет доступа «Универсальный доступ» для табов.")
    }
    /// The `.custom` twin of the above: that launch is not waited on, so this timeout is its only
    /// failure channel — the message must point at the command the user typed, not at Ghostty.
    static var terminalCustomDidNotStart: String {
        t("Command did not start in the terminal — the launch command probably failed: check the terminal’s path and that it keeps {script} running.",
          "Команда не стартовала в терминале — скорее всего не сработала команда запуска: проверьте путь к терминалу и что он действительно запускает {script}.")
    }
    /// Footer line printed inside the Ghostty tab when a command finishes.
    static func terminalDoneFooter(_ codeVar: String) -> String {
        t("[DevDeck] finished (code \(codeVar)). Press Enter to close.",
          "[DevDeck] завершено (код \(codeVar)). Enter — закрыть.")
    }
    /// Footer for a tab that stays open — the command is done, the shell is yours.
    static func terminalStaysOpenFooter(_ codeVar: String) -> String {
        t("[DevDeck] finished (code \(codeVar)). The shell is yours.",
          "[DevDeck] завершено (код \(codeVar)). Шелл в вашем распоряжении.")
    }

    // MARK: - Chain script (user-visible)

    static var noCommandMarker: String { t("✗ no command", "✗ нет команды") }

    // MARK: - Host memory monitoring (Tier 1)

    static var hostMonitoringToggle: String {
        t("Host memory: pressure, swap rate, build peak, OOM detection",
          "Память хоста: давление, swap-rate, пик сборки, OOM-детект")
    }
    static var pressure: String { t("Pressure", "Давление") }
    /// The pressure level as a standalone value word (shown right-aligned, colored by level).
    static func pressureValue(_ level: MemoryPressureLevel) -> String {
        switch level {
        case .normal: return t("Normal", "Норма")
        case .warning: return t("Warning", "Тревога")
        case .critical: return t("Critical", "Критично")
        }
    }
    static var swapRate: String { t("Swap rate", "Swap-rate") }
    static var cpuLoad: String { t("CPU load", "Загрузка CPU") }
    static var diskVM: String { t("VM disk", "Диск VM") }
    static var clusterHealthToggle: String {
        t("Cluster health (colima + minikube status in the deck)",
          "Здоровье кластера (статус colima + minikube в деке)")
    }
    static var cluster: String { t("Cluster", "Кластер") }
    static func clusterHealthValue(_ level: ClusterHealthLevel) -> String {
        switch level {
        case .healthy: return t("Healthy", "В норме")
        case .degraded: return t("Degraded", "Деградация")
        case .down: return t("Down", "Не работает")
        case .unknown: return t("Unknown", "Неизвестно")
        }
    }
    static func jobsAdvice(_ effective: Int, _ advised: Int) -> String {
        t("Build uses \(effective) jobs; safe for this RAM limit: \(advised)",
          "Сборка: \(effective) задач; безопасно для лимита RAM: \(advised)")
    }

    // MARK: - Proxy manager

    static var proxy: String { t("Proxy", "Прокси") }
    static var proxySection: String { t("Proxy manager", "Менеджер прокси") }
    /// Name of the synthetic gost daemon — logs use this instead of the command line,
    /// which keeps the password out of the log.
    static var proxyShareDaemonName: String { t("Proxy (gost)", "Прокси (gost)") }
    static var proxyShareDaemonNameBuiltIn: String { t("Proxy (built-in)", "Прокси (встроенный)") }
    static var proxyEngine: String { t("Engine", "Движок") }
    static var proxyEngineBuiltIn: String { t("Built-in", "Встроенный") }
    static var proxyEngineGost: String { t("gost (system)", "gost (системный)") }
    static var proxyEngineHint: String {
        t("Built-in serves HTTP (CONNECT) — enough for every DevDeck client and dp. Pick gost if a peer needs SOCKS.",
          "Встроенный отдаёт HTTP (CONNECT) — этого достаточно всем клиентам DevDeck и dp. gost нужен, только если пиру требуется SOCKS.")
    }
    static var proxyShareSection: String { t("Share this Mac’s proxy", "Раздавать прокси с этого мака") }
    static var proxyShareToggle: String {
        t("Share the proxy on the local network", "Раздавать прокси в локальной сети")
    }
    static var proxyDiscoverySection: String { t("Use a proxy from the network", "Использовать прокси из сети") }
    static var proxyDiscoveryToggle: String {
        t("Look for proxies on the local network", "Искать прокси в локальной сети")
    }
    static var routeThroughProxyToggle: String {
        t("Route through the LAN proxy", "Пускать через прокси из локальной сети")
    }
    static var proxyActive: String { t("Active", "Активный") }
    static var proxyNone: String { t("none", "нет") }
    static var proxyAuthRequired: String { t("Password required", "Требуется пароль") }
    static var proxyExitIP: String { t("Exit IP", "Внешний IP") }
    static var proxyAdvertising: String { t("Announced on the network", "Анонсируется в сети") }
    static var proxyNotAdvertising: String { t("Not announced", "Не анонсируется") }
    static var proxyServiceName: String { t("Name on the network", "Имя в сети") }
    static var proxyUsername: String { t("Username", "Пользователь") }
    static var proxyPassword: String { t("Password", "Пароль") }
    static var proxyAuthToggle: String { t("Require a password", "Требовать пароль") }
    static var proxyPort: String { t("Port", "Порт") }
    static var proxyCheck: String { t("Check", "Проверить") }
    static var proxyChecking: String { t("Checking…", "Проверяем…") }
    static var proxyCheckFailed: String { t("No response through the proxy", "Прокси не отвечает") }
    static var proxySearching: String { t("Searching…", "Идёт поиск…") }
    static var proxyNoneFound: String { t("No proxies found yet", "Прокси пока не найдены") }
    static var proxyLastKnownAddress: String {
        t("Last known address — not announced right now",
          "Последний известный адрес — сейчас не анонсируется")
    }
    static var gostNotFound: String {
        t("gost not found (install it: brew install gost)", "gost не найден (установите: brew install gost)")
    }
    static var proxyUnavailable: String {
        t("No active proxy — the command was not started. Pick one under Proxy, or turn the flag off.",
          "Нет активного прокси — команда не запущена. Выберите его в разделе «Прокси» или снимите флаг.")
    }
    static var notifProxyUnavailable: String { t("Proxy unavailable", "Прокси недоступен") }
    static var proxyPortHint: String {
        t("The port gost listens on — announced to the network and checked for conflicts, exactly like a daemon’s port.",
          "Порт, который слушает gost — анонсируется в сеть и проверяется на конфликт, как и у обычного демона.")
    }
    static var proxyIsolatedNetworkHint: String {
        t("Discovery uses Bonjour: it needs both Macs on the same Wi-Fi without client isolation (guest networks usually block it).",
          "Обнаружение работает по Bonjour: нужны оба мака в одной Wi-Fi без изоляции клиентов (в гостевых сетях обычно заблокировано).")
    }
    static var proxyNoActiveHint: String {
        t("No active proxy selected — a command with this flag will fail instead of running unprotected.",
          "Активный прокси не выбран — команда с этим флагом упадёт, а не запустится в обход.")
    }
    static func proxyRoutedVia(_ name: String) -> String {
        t("Traffic goes through “\(name)”", "Трафик пойдёт через «\(name)»")
    }
    static func proxyEndpoint(_ host: String, _ port: Int) -> String { "\(host):\(port)" }

    // MARK: - Proxy: connected machines (host side)

    static var proxyConnectedSection: String { t("Connected machines", "Подключённые машины") }
    static var proxyNoConnections: String {
        t("Nobody has connected yet", "Пока никто не подключался")
    }
    static var proxyClientActive: String { t("active", "активна") }
    /// Written as "sessions: N" in both languages — it sidesteps English and Russian number
    /// agreement, so no plural helper is needed anywhere in the catalog.
    static func proxySessions(_ count: Int) -> String {
        t("sessions: \(count)", "сессий: \(count)")
    }
    static func proxyLastSeen(_ minutes: Int) -> String {
        minutes < 1 ? t("just now", "только что") : t("\(minutes) min ago", "\(minutes) мин назад")
    }
    /// Same trick: "connected N", not "N machines".
    static func proxyConnectedCount(_ count: Int) -> String {
        t("connected \(count)", "подключено \(count)")
    }

    static var promptForDirectoryToggle: String {
        t("Ask for a directory on every run", "Спрашивать директорию при каждом запуске")
    }
    static var promptForDirectoryHint: String {
        t("One command for every project: the directory is chosen at launch and never saved. The field above is where the picker opens — and what a chain step or the watchdog shield falls back to, since neither can ask.",
          "Одна команда на все проекты: директория выбирается при запуске и не сохраняется. Поле выше — стартовая папка диалога, и его же используют шаг цепочки и щит watchdog: спросить они не могут.")
    }
    static var chooseRunDirectory: String { t("Run here", "Запустить здесь") }
    static func chooseRunDirectoryMessage(_ name: String) -> String {
        t("Choose the directory to run “\(name)” in", "Выберите директорию для запуска «\(name)»")
    }
    static var proxyTerminalHelperSection: String { t("Terminal helper", "Помощник для терминала") }
    static var proxyTerminalHelperHint: String {
        t("Paste this into ~/.zshrc, then run anything through the active proxy from any directory: dp claude. It reads the file below and refuses if that proxy is not on the current network.",
          "Вставьте это в ~/.zshrc, и запускайте что угодно через активный прокси из любой директории: dp claude. Функция читает файл ниже и откажется работать, если этот прокси не в текущей сети.")
    }
    /// Shown only when the active proxy needs a password: a shell cannot read the Keychain, so the
    /// helper's file has to carry that password in plaintext. The person pasting the snippet has not
    /// read the design document that accepted this trade-off — say it where they will see it.
    static var proxyTerminalHelperPasswordWarning: String {
        t("This proxy needs a password, and a shell cannot read the Keychain — so DevDeck writes that password into the file below in plain text, readable only by you (mode 0600). Deselecting the proxy deletes the file.",
          "Этот прокси требует пароль, а из терминала Keychain не прочитать — поэтому DevDeck записывает пароль в файл ниже в открытом виде, доступный только вам (права 0600). Когда прокси снят с выбора, файл удаляется.")
    }
    static var copy: String { t("Copy", "Копировать") }
    static var copied: String { t("Copied", "Скопировано") }

    // MARK: - Duplicate

    static var duplicate: String { t("Duplicate", "Дублировать") }
    /// The word written into a duplicate's name: `deploy` → `deploy (copy)`.
    /// Distinct from `copy` above, which is the clipboard verb.
    static var copyMarker: String { t("copy", "копия") }
    /// Every marker DevDeck can recognize inside an existing name — not just the active language's.
    /// Names live in config.json and outlive a language switch, so a copy made in Russian must
    /// still be recognized as a copy after switching to English.
    static let copyMarkers = ["copy", "копия"]
}
