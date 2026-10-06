import SwiftUI

struct PrototypeWindow: View {
    @Environment(PrototypeModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    private let groups: [(String, [PrototypePage])] = [
        ("Настройки DevDeck", [.general, .layout, .permissions, .automation, .updates]),
        ("Среда разработки", [.commands, .ports, .proxy, .sessions, .cleanup]),
        ("Наблюдение", [.monitoring, .traffic, .energy]),
        ("Инструменты Mac", [.displays, .awake, .clipboard])
    ]

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(selection: Binding(get: { model.page }, set: { if let page = $0 { model.navigate(page) } })) {
                ForEach(groups, id: \.0) { title, pages in
                    Section(title) {
                        ForEach(pages) { page in
                            Label(page.title, systemImage: page.symbol).tag(page)
                                .accessibilityIdentifier("page-\(page.rawValue)")
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 210, ideal: 235, max: 290)
            .safeAreaInset(edge: .bottom) {
                Label("Прототип · данные примеры", systemImage: "hammer")
                    .font(.caption).foregroundStyle(.secondary)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(.bar)
            }
        } detail: {
            detail
                .navigationTitle(model.page?.title ?? "DevDeck")
                .toolbar {
                    ToolbarItem {
                        Button("Показать панель", systemImage: "menubar.rectangle") { openWindow(id: "panel") }
                            .help("Открыть панель рядом с конфигурацией")
                            .accessibilityIdentifier("show-panel")
                    }
                    ToolbarItem {
                        Menu {
                            Picker("Сценарий", selection: Binding(get: { model.scenario }, set: { model.applyScenario($0) })) {
                                ForEach(DemoScenario.allCases) { Text($0.title).tag($0) }
                            }
                            Picker("Оформление", selection: $model.appearance) {
                                ForEach(DemoAppearance.allCases) { Text($0.title).tag($0) }
                            }
                            Divider()
                            Button("Сбросить макет") { model.reset() }
                        } label: { Label("Сценарии макета", systemImage: "slider.horizontal.3") }
                        .accessibilityIdentifier("demo-scenarios")
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    VStack(spacing: 0) {
                        Divider()
                        Text(model.message).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }.background(.bar)
                }
        }
        .frame(minWidth: 820, minHeight: 620)
        .task {
            model.presentInitialPage()
            if CommandLine.arguments.contains("--show-panel") { openWindow(id: "panel") }
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.page ?? .layout {
        case .general: GeneralSettingsPage()
        case .layout: ModuleLayoutPage()
        case .displays: DisplaysPage()
        case .clipboard: ClipboardPage()
        case .commands: CommandsPage()
        case .ports: PortsPage()
        case .proxy: ProxyPage()
        case .monitoring: MonitoringPage()
        case .traffic: TrafficPage()
        case .energy: EnergyPage()
        case .awake: AwakePage()
        case .sessions: SessionsPage()
        case .cleanup: CleanupPage()
        case .permissions: PermissionsPage()
        case .automation: AutomationPage()
        case .updates: UpdatesPage()
        }
    }
}

struct ModuleLayoutPage: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(model.tabs) { ModuleColumn(tab: $0).frame(minWidth: 145) }
                    }
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 12) {
                        ForEach(model.tabs) { ModuleColumn(tab: $0) }
                    }
                }
            } header: {
                Text("Вкладки панели")
            } footer: {
                Text("Перетаскивайте модули между вкладками и на строки для изменения порядка. Выключенный переключатель только скрывает модуль: работающие команды, порты и прокси продолжают работать.")
            }
            Section("Поведение панели") {
                Toggle("Возвращаться на последнюю вкладку", isOn: $model.rememberTab)
                Picker("Начальная вкладка", selection: $model.firstTab) {
                    ForEach(model.tabs) { Text($0.title).tag($0) }
                }.disabled(model.rememberTab)
                Toggle("Показывать строку памяти во вкладке «Среда»", isOn: $model.pinnedMemory)
            }
        }.formStyle(.grouped)
    }
}

private struct ModuleColumn: View {
    @Environment(PrototypeModel.self) private var model
    let tab: DeckTab
    @State private var targeted = false
    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(model.modules[tab] ?? []) { module in
                    HStack(spacing: 6) {
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                            .imageScale(.small)
                        Text(module.title).font(.callout).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                        Toggle(module.title, isOn: Binding(
                            get: { !model.hiddenModules.contains(module) },
                            set: { model.setVisible(module, $0) }
                        )).labelsHidden().toggleStyle(.switch).controlSize(.mini)
                            .accessibilityIdentifier("visible-\(module.rawValue)")
                    }
                    .padding(6).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                    .draggable(module.rawValue)
                    .dropDestination(for: String.self) { items, _ in
                        guard let first = items.first, let moved = DeckModule(rawValue: first) else { return false }
                        model.move(moved, to: tab, before: module)
                        return true
                    }
                    .contextMenu {
                        Menu("Перенести во вкладку") {
                            ForEach(model.tabs) { destination in
                                Button(destination.title) { model.move(module, to: destination) }
                            }
                        }
                        Button("Выше") { model.shift(module, by: -1) }
                        Button("Ниже") { model.shift(module, by: 1) }
                    }
                }
                if model.modules[tab]?.isEmpty == true {
                    Text("Перетащите модуль сюда").font(.caption).foregroundStyle(.secondary).padding(.vertical, 16)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 6)
        } label: {
            HStack {
                Label(tab.title, systemImage: tab.symbol)
                Spacer(minLength: 0)
                Menu {
                    Button("Передвинуть вкладку влево") { shiftTab(-1) }
                    Button("Передвинуть вкладку вправо") { shiftTab(1) }
                } label: { Image(systemName: "ellipsis") }
                    .menuStyle(.borderlessButton).frame(width: 16)
                    .help("Порядок вкладок")
            }
        }
        .overlay {
            if targeted { RoundedRectangle(cornerRadius: 8).stroke(.tint, lineWidth: 2).allowsHitTesting(false) }
        }
        .dropDestination(for: String.self) { items, _ in
            guard let first = items.first, let module = DeckModule(rawValue: first) else { return false }
            model.move(module, to: tab)
            return true
        } isTargeted: { targeted = $0 }
    }
    private func shiftTab(_ delta: Int) {
        guard let index = model.tabs.firstIndex(of: tab), model.tabs.indices.contains(index + delta) else { return }
        model.tabs.swapAt(index, index + delta)
    }
}
