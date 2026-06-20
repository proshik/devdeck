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
    static func notifNameCode(_ name: String, _ code: Int32) -> String {
        t("\(name) — code \(code)", "\(name) — код \(code)")
    }
    static func notifMemoryHigh(_ target: String) -> String {
        t("\(target) memory is running low", "\(target): память на исходе")
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
    static var terminalDidNotStart: String {
        t("Command did not start in the terminal — Ghostty did not open or Accessibility access for tabs is missing.",
          "Команда не стартовала в терминале — Ghostty не открылся или нет доступа «Универсальный доступ» для табов.")
    }
    /// Footer line printed inside the Ghostty tab when a command finishes.
    static func terminalDoneFooter(_ codeVar: String) -> String {
        t("[DevDeck] finished (code \(codeVar)). Press Enter to close.",
          "[DevDeck] завершено (код \(codeVar)). Enter — закрыть.")
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
    static var compressor: String { t("Compressor", "Компрессор") }
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
}
