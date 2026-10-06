import SwiftUI
import Observation

enum DeckTab: String, CaseIterable, Identifiable {
    case environment, monitoring, displays, clipboard
    var id: Self { self }
    var title: String {
        switch self {
        case .environment: "Среда"
        case .monitoring: "Мониторинг"
        case .displays: "Экраны"
        case .clipboard: "Буфер"
        }
    }
    var symbol: String {
        switch self {
        case .environment: "terminal"
        case .monitoring: "waveform.path.ecg"
        case .displays: "display"
        case .clipboard: "clipboard"
        }
    }
}

enum DeckModule: String, CaseIterable, Identifiable {
    case commands, daemons, chains, ports, proxy, sessions
    case system, containers, traffic, energy, brightness, awake, clipboard
    var id: Self { self }
    var title: String {
        switch self {
        case .commands: "Команды"
        case .daemons: "Фоновые процессы"
        case .chains: "Цепочки"
        case .ports: "Пробросы портов"
        case .proxy: "Прокси"
        case .sessions: "Сессии агентов"
        case .system: "Этот Mac"
        case .containers: "Контейнеры"
        case .traffic: "Трафик сети"
        case .energy: "Питание"
        case .brightness: "Яркость"
        case .awake: "Не засыпать"
        case .clipboard: "История буфера"
        }
    }
    var tab: DeckTab {
        switch self {
        case .commands, .daemons, .chains, .ports, .proxy, .sessions: .environment
        case .system, .containers, .traffic, .energy: .monitoring
        case .brightness, .awake: .displays
        case .clipboard: .clipboard
        }
    }
    var symbol: String {
        switch self {
        case .commands: "terminal"
        case .daemons: "infinity"
        case .chains: "link"
        case .ports: "arrow.left.arrow.right"
        case .proxy: "network"
        case .sessions: "macwindow.on.rectangle"
        case .system: "cpu"
        case .containers: "shippingbox"
        case .traffic: "arrow.up.arrow.down"
        case .energy: "battery.100percent"
        case .brightness: "sun.max"
        case .awake: "cup.and.saucer"
        case .clipboard: "clipboard"
        }
    }
    var page: PrototypePage {
        switch self {
        case .commands, .daemons, .chains: .commands
        case .ports: .ports
        case .proxy: .proxy
        case .sessions: .sessions
        case .system, .containers: .monitoring
        case .traffic: .traffic
        case .energy: .energy
        case .brightness: .displays
        case .awake: .awake
        case .clipboard: .clipboard
        }
    }
}

enum PrototypePage: String, CaseIterable, Identifiable {
    case general, layout, permissions, automation, updates
    case commands, ports, proxy, sessions, cleanup
    case monitoring, traffic, energy, displays, awake, clipboard
    var id: Self { self }
    var title: String {
        switch self {
        case .general: "Общие"
        case .layout: "Панель и модули"
        case .permissions: "Разрешения"
        case .automation: "Автоматизация"
        case .updates: "Обновления DevDeck"
        case .commands: "Команды и цепочки"
        case .ports: "Пробросы портов"
        case .proxy: "Прокси"
        case .sessions: "Сессии агентов"
        case .cleanup: "Очистка контейнеров"
        case .monitoring: "Мониторинг Mac"
        case .traffic: "Трафик сети"
        case .energy: "Энергия"
        case .displays: "Экраны"
        case .awake: "Не засыпать"
        case .clipboard: "Буфер обмена"
        }
    }
    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .layout: "square.grid.2x2"
        case .permissions: "lock.shield"
        case .automation: "bolt"
        case .updates: "arrow.down.circle"
        case .commands: "terminal"
        case .ports: "arrow.left.arrow.right"
        case .proxy: "network"
        case .sessions: "macwindow.on.rectangle"
        case .cleanup: "trash"
        case .monitoring: "waveform.path.ecg"
        case .traffic: "arrow.up.arrow.down"
        case .energy: "battery.100percent"
        case .displays: "display"
        case .awake: "cup.and.saucer"
        case .clipboard: "clipboard"
        }
    }
}

enum DemoScenario: String, CaseIterable, Identifiable {
    case normal, portOccupied, disconnected, emptyClipboard, pastePermission, recovery
    var id: Self { self }
    var title: String {
        switch self {
        case .normal: "Обычная работа"
        case .portOccupied: "Порт занят"
        case .disconnected: "Монитор отключён"
        case .emptyClipboard: "Пустой буфер"
        case .pastePermission: "Нет доступа к вставке"
        case .recovery: "Восстановление после сбоя"
        }
    }
}

enum DemoAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String {
        switch self { case .system: "Системная"; case .light: "Светлая"; case .dark: "Тёмная" }
    }
    var scheme: ColorScheme? {
        switch self { case .system: nil; case .light: .light; case .dark: .dark }
    }
}

struct DemoDisplay: Identifiable {
    let id: String
    let name: String
    let subtitle: String
    let symbol: String
    var brightness: Double
}

struct DemoCommand: Identifiable {
    let id = UUID()
    var name: String
    var command: String
    var directory = "~/work/project"
    var kind: DeckModule
    var running = false
    var port: String = ""
    var watchdog = true
    var proxy = false
}

struct DemoClip: Identifiable {
    enum Kind: String, CaseIterable {
        case text = "Текст", image = "Изображения", file = "Файлы"
        var symbol: String {
            switch self { case .text: "text.alignleft"; case .image: "photo"; case .file: "doc" }
        }
    }
    let id: Int
    let kind: Kind
    let content: String
    let source: String
    let time: String
    var pinned = false
}

/// All prototype actions mutate this in-memory model. No production stores or probes are used.
@MainActor @Observable
final class PrototypeModel {
    @ObservationIgnored private var initialPage: PrototypePage?
    var page: PrototypePage? = .layout
    var activeTab: DeckTab = .environment
    var monitoringModule: DeckModule = .system
    var tabs = DeckTab.allCases
    var modules = Dictionary(uniqueKeysWithValues: DeckTab.allCases.map { tab in
        (tab, DeckModule.allCases.filter { $0.tab == tab })
    })
    var hiddenModules: Set<DeckModule> = []
    var scenario: DemoScenario = .normal
    var appearance: DemoAppearance = .system
    var interfaceLanguage = "Русский"
    var launchAtLogin = false
    var globalHotkey = true
    var rememberTab = true
    var firstTab: DeckTab = .environment
    var pinnedMemory = false
    var proxyConnected = true
    var sharingProxy = false
    var proxyEngine = "Встроенный"
    var awake = false
    var awakeDuration = "2 часа"
    var nativeKeys = true
    var linkedSliders = false
    var linkedKeys = false
    var cursorDisplay = "studio"
    var displays: [DemoDisplay] = [
        .init(id: "macbook", name: "MacBook Pro", subtitle: "Встроенный экран", symbol: "laptopcomputer", brightness: 68),
        .init(id: "studio", name: "Studio Display", subtitle: "Основной экран", symbol: "display", brightness: 54),
        .init(id: "dell", name: "DELL U2723QE", subtitle: "Внешний экран", symbol: "display", brightness: 42)
    ]
    var commands: [DemoCommand] = [
        .init(name: "Собрать проект", command: "just dev-build", kind: .commands),
        .init(name: "Запустить тесты", command: "just test", kind: .commands),
        .init(name: "API", command: "just dev-api", kind: .daemons, running: true, port: "8080"),
        .init(name: "Redis", command: "redis-server", kind: .daemons, port: "6379"),
        .init(name: "PostgreSQL", command: "kubectl port-forward svc/postgres 15432:5432", kind: .ports, running: true, port: "15432")
    ]
    var selectedCommand: UUID?
    var query = ""
    var clipFilter = "Все"
    var recording = true
    var pasteEnabled = false
    var clipLimit = 100
    var retention = "7 дней"
    var exclusions = "1Password\nPasswords"
    var selectedClip: Int? = 1
    var clips = PrototypeModel.exampleClips
    var monitoringHistory = true
    var restoreSessions = true
    var automaticUpdates = true
    var cleanupSize = "18,4 ГБ"
    var message = "Демонстрационные данные. Действия меняют только прототип."

    static let exampleClips: [DemoClip] = [
        .init(id: 1, kind: .text, content: "kubectl get pods -n development", source: "Ghostty", time: "Сейчас", pinned: true),
        .init(id: 2, kind: .text, content: "http://127.0.0.1:8080", source: "Safari", time: "2 минуты назад"),
        .init(id: 3, kind: .image, content: "Панель метрик.png", source: "Снимок экрана", time: "5 минут назад"),
        .init(id: 4, kind: .file, content: "config.json", source: "Finder", time: "8 минут назад"),
        .init(id: 5, kind: .text, content: "Исправить восстановление сессий после перезагрузки", source: "Заметки", time: "12 минут назад"),
        .init(id: 6, kind: .text, content: "{\"routeThroughProxy\": true}", source: "Xcode", time: "18 минут назад")
    ]

    init() {
        selectedCommand = commands.first?.id
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--page"), args.indices.contains(i + 1),
           let initial = PrototypePage(rawValue: args[i + 1]) { initialPage = initial; navigate(initial) }
        if let i = args.firstIndex(of: "--appearance"), args.indices.contains(i + 1),
           let value = DemoAppearance(rawValue: args[i + 1]) { appearance = value }
        if let i = args.firstIndex(of: "--scenario"), args.indices.contains(i + 1),
           let value = DemoScenario(rawValue: args[i + 1]) { applyScenario(value) }
        if initialPage != nil { initialPage = page }
    }

    var visibleTabs: [DeckTab] { tabs.filter { !visibleModules(in: $0).isEmpty } }
    func presentInitialPage() {
        guard let destination = initialPage else { return }
        initialPage = nil
        navigate(destination)
    }
    func visibleModules(in tab: DeckTab) -> [DeckModule] {
        (modules[tab] ?? []).filter { !hiddenModules.contains($0) }
    }
    func placement(of module: DeckModule) -> DeckTab {
        tabs.first { modules[$0]?.contains(module) == true } ?? module.tab
    }
    func ensureVisibleTab() {
        if !visibleTabs.contains(activeTab) { activeTab = visibleTabs.first ?? .environment }
    }
    func setVisible(_ module: DeckModule, _ visible: Bool) {
        if visible { hiddenModules.remove(module) } else { hiddenModules.insert(module) }
        ensureVisibleTab()
    }
    func move(_ module: DeckModule, to tab: DeckTab, before target: DeckModule? = nil) {
        guard module != target else { return }
        for source in tabs { modules[source]?.removeAll { $0 == module } }
        let index = target.flatMap { modules[tab]?.firstIndex(of: $0) } ?? (modules[tab]?.count ?? 0)
        modules[tab, default: []].insert(module, at: index)
        ensureVisibleTab()
    }
    func shift(_ module: DeckModule, by delta: Int) {
        let tab = placement(of: module)
        guard var list = modules[tab], let from = list.firstIndex(of: module),
              list.indices.contains(from + delta) else { return }
        list.swapAt(from, from + delta)
        modules[tab] = list
    }
    func navigate(_ destination: PrototypePage) {
        page = destination
        if destination == .traffic { monitoringModule = .traffic }
        if destination == .energy { monitoringModule = .energy }
        if destination == .monitoring { monitoringModule = .system }
        if let module = DeckModule.allCases.first(where: { $0.page == destination }) {
            activeTab = placement(of: module)
            ensureVisibleTab()
        }
    }
    func isConnected(_ display: DemoDisplay) -> Bool {
        !(scenario == .disconnected && display.id == "dell")
    }
    func setBrightness(_ id: String, to value: Double, fromKey: Bool = false) {
        guard let index = displays.firstIndex(where: { $0.id == id }), isConnected(displays[index]) else {
            message = "Выбранный экран отключён. Яркость остальных экранов сохранена."
            return
        }
        let value = min(100, max(0, value))
        displays[index].brightness = value
        let sync = fromKey ? (linkedSliders && linkedKeys) : linkedSliders
        if sync {
            for i in displays.indices where isConnected(displays[i]) { displays[i].brightness = value }
        }
        message = "Пример: \(displays[index].name) — \(Int(value))%."
    }
    func brightnessKey(_ delta: Double) {
        guard nativeKeys else { message = "Обработка клавиш выключена в прототипе."; return }
        guard let display = displays.first(where: { $0.id == cursorDisplay }) else { return }
        setBrightness(display.id, to: display.brightness + delta, fromKey: true)
    }
    func toggleCommand(_ id: UUID) {
        guard let index = commands.firstIndex(where: { $0.id == id }) else { return }
        if scenario == .portOccupied && commands[index].kind == .ports {
            navigate(.ports)
            message = "Порт 15432 занят. Завершение другого процесса требует подтверждения."
            return
        }
        commands[index].running.toggle()
        message = "Пример: \(commands[index].name) \(commands[index].running ? "запущен" : "остановлен")."
    }
    var filteredClips: [DemoClip] {
        clips.filter { clip in
            (clipFilter == "Все" || (clipFilter == "Закреплённые" && clip.pinned) || clipFilter == clip.kind.rawValue)
            && (query.isEmpty || (clip.content + " " + clip.source).localizedCaseInsensitiveContains(query))
        }.sorted { $0.pinned != $1.pinned ? $0.pinned : $0.id < $1.id }
    }
    func togglePin(_ id: Int) {
        guard let i = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[i].pinned.toggle()
    }
    func copy(_ clip: DemoClip) { message = "Пример: «\(clip.content)» скопировано. Системный буфер не изменён." }
    func applyScenario(_ value: DemoScenario) {
        let previous = scenario
        scenario = value
        if previous == .emptyClipboard {
            clips = Self.exampleClips
            selectedClip = clips.first?.id
        }
        switch value {
        case .normal: break
        case .portOccupied: navigate(.ports)
        case .disconnected: navigate(.displays)
        case .emptyClipboard:
            clips = []; selectedClip = nil; query = ""; clipFilter = "Все"; navigate(.clipboard)
        case .pastePermission: pasteEnabled = true; navigate(.clipboard)
        case .recovery: navigate(.updates)
        }
        message = "Сценарий: \(value.title). Данные демонстрационные."
    }
    func reset() {
        let fresh = PrototypeModel()
        // Build the defaults explicitly; a reset does not consult saved configuration.
        modules = Dictionary(uniqueKeysWithValues: DeckTab.allCases.map { tab in (tab, DeckModule.allCases.filter { $0.tab == tab }) })
        tabs = DeckTab.allCases; hiddenModules = []; activeTab = .environment; monitoringModule = .system; page = .layout
        scenario = .normal; displays = fresh.displays; commands = fresh.commands; selectedCommand = commands.first?.id
        proxyConnected = true; sharingProxy = false; awake = false
        nativeKeys = true; linkedSliders = false; linkedKeys = false; cursorDisplay = "studio"
        clips = Self.exampleClips; selectedClip = 1; query = ""; clipFilter = "Все"; recording = true; pasteEnabled = false
        rememberTab = true; firstTab = .environment; pinnedMemory = false; proxyEngine = "Встроенный"
        awakeDuration = "2 часа"; clipLimit = 100; retention = "7 дней"; exclusions = "1Password\nPasswords"
        monitoringHistory = true; restoreSessions = true; automaticUpdates = true; cleanupSize = "18,4 ГБ"
        interfaceLanguage = "Русский"; launchAtLogin = false; globalHotkey = true
        message = "Макет сброшен. Данные демонстрационные."
    }
}
