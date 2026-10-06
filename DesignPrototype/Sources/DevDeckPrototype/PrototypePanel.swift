import AppKit
import SwiftUI

private enum PanelLayout {
    static let inset: CGFloat = 16
    static let sectionSpacing: CGFloat = 10
    static let controlHeight: CGFloat = 24
}

struct PrototypePanel: View {
    @Environment(PrototypeModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @State private var contentHeight: CGFloat = 1

    private var panelModules: [DeckModule] { model.visibleModules(in: model.activeTab) }
    private var selection: DeckModule { panelModules.contains(model.monitoringModule) ? model.monitoringModule : (panelModules.first ?? .system) }
    private var maximumContentHeight: CGFloat {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        return min(560, max(120, (screen?.visibleFrame.height ?? 800) - 160))
    }

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("DevDeck").font(.headline)
                Text("Прототип").font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Button("Настройки DevDeck…", systemImage: "gearshape") { show(.general) }
                    .labelStyle(.iconOnly).buttonStyle(.borderless)
                    .font(.body)
                    .frame(width: PanelLayout.controlHeight, height: PanelLayout.controlHeight).help("Настройки DevDeck")
            }.padding(.horizontal, PanelLayout.inset).padding(.vertical, 8)
            if !model.visibleTabs.isEmpty {
                PanelTabPicker(tabs: model.visibleTabs, selection: $model.activeTab)
                    .frame(maxWidth: .infinity).padding(.horizontal, PanelLayout.inset).padding(.bottom, 12)
            }
            Divider()
            ScrollView {
                panelContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        ceil(geometry.size.height)
                    } action: { height in
                        if contentHeight != height { contentHeight = height }
                    }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maximumContentHeight))

        }
        .font(.body)
        .frame(width: 380)
        .fixedSize(horizontal: false, vertical: true)
        .background(.background)
        .onAppear {
            if !model.rememberTab {
                model.activeTab = model.visibleTabs.contains(model.firstTab) ? model.firstTab : (model.visibleTabs.first ?? .environment)
            }
        }
    }

    @ViewBuilder private var panelContent: some View {
        if model.scenario == .recovery {
            VStack(alignment: .leading, spacing: 8) {
                Label("Режим восстановления", systemImage: "exclamationmark.shield").fontWeight(.medium)
                Text("Конфигурация и снимки сессий сохранены.").foregroundStyle(.secondary)
                Button("Открыть диагностику") { show(.updates) }.controlSize(.small)
            }.padding(PanelLayout.inset)
        } else if model.visibleTabs.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Все модули скрыты", systemImage: "square.grid.2x2")
                Button("Настроить панель") { show(.layout) }.controlSize(.small)
            }.padding(PanelLayout.inset)
        } else {
            VStack(spacing: 0) {
                if model.activeTab == .environment && model.pinnedMemory {
                    PanelMetricRow(title: "Память", value: "35,6 / 48 ГБ", symbol: "memorychip", color: .green)
                        .padding(.horizontal, PanelLayout.inset).padding(.vertical, PanelLayout.sectionSpacing)
                    Divider().padding(.horizontal, PanelLayout.inset)
                }
                if model.activeTab == .monitoring {
                    if panelModules.count > 1 {
                        Picker("Показатели", selection: Binding(get: { selection }, set: { model.monitoringModule = $0 })) {
                            ForEach(panelModules) { Text(shortTitle($0)).tag($0) }
                        }.pickerStyle(.segmented).labelsHidden().controlSize(.small)
                            .padding(.horizontal, PanelLayout.inset).padding(.top, PanelLayout.sectionSpacing)
                    }
                    PanelModuleView(module: selection)
                } else {
                    ForEach(panelModules) { module in
                        PanelModuleView(module: module)
                        if module != panelModules.last { Divider().padding(.horizontal, PanelLayout.inset) }
                    }
                }
                if model.activeTab == .environment && model.hiddenModules.contains(.proxy) && model.proxyConnected {
                    HStack {
                        Label("Прокси VDS работает", systemImage: "network").foregroundStyle(.secondary)
                        Spacer()
                        Button("Открыть") { show(.proxy) }.buttonStyle(.plain).foregroundStyle(.tint)
                    }.font(.caption).padding(.horizontal, PanelLayout.inset).padding(.vertical, PanelLayout.sectionSpacing)
                }
            }
        }
    }

    private func show(_ page: PrototypePage) { model.navigate(page); openWindow(id: "main") }
    private func shortTitle(_ module: DeckModule) -> String {
        switch module {
        case .system: "Mac"
        case .containers: "Контейнеры"
        case .traffic: "Трафик"
        case .energy: "Питание"
        default: module.title
        }
    }
}

/// Named native tabs below the panel header.
private struct PanelTabPicker: NSViewRepresentable {
    let tabs: [DeckTab]
    @Binding var selection: DeckTab

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.controlSize = .regular
        control.segmentStyle = .rounded
        control.selectedSegmentBezelColor = .controlAccentColor
        control.segmentDistribution = .fill
        control.font = .systemFont(ofSize: NSFont.systemFontSize)
        control.trackingMode = .selectOne
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectTab(_:))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.segmentCount = tabs.count
        control.setAccessibilityLabel("Раздел панели")
        for (index, tab) in tabs.enumerated() {
            control.setLabel(tab.title, forSegment: index)
            control.setToolTip(tab.title, forSegment: index)
        }
        control.selectedSegment = tabs.firstIndex(of: selection) ?? -1
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSSegmentedControl, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? nsView.intrinsicContentSize.width, height: PanelLayout.controlHeight)
    }

    @MainActor final class Coordinator: NSObject {
        var parent: PanelTabPicker
        init(_ parent: PanelTabPicker) { self.parent = parent }
        @objc func selectTab(_ sender: NSSegmentedControl) {
            guard parent.tabs.indices.contains(sender.selectedSegment) else { return }
            parent.selection = parent.tabs[sender.selectedSegment]
        }
    }
}

private struct PanelModuleView: View {
    @Environment(PrototypeModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    let module: DeckModule

    var body: some View {
        Group {
            if [.chains, .proxy, .sessions, .awake].contains(module) {
                HStack(spacing: 4) {
                    content
                    openConfiguration
                }.frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(module == .clipboard && !model.recording ? "История · пауза" : module.title)
                            .font(.caption).fontWeight(.semibold).foregroundStyle(.secondary)
                        Spacer()
                        if module == .clipboard {
                            Button(model.recording ? "Пауза" : "Продолжить", systemImage: model.recording ? "pause" : "play") { model.recording.toggle() }
                                .labelStyle(.iconOnly).buttonStyle(.borderless).frame(width: 28, height: 28)
                                .help(model.recording ? "Приостановить запись" : "Продолжить запись")
                        }
                        openConfiguration
                    }
                    VStack(alignment: .leading, spacing: 4) { content }
                }
            }
        }.padding(.horizontal, PanelLayout.inset).padding(.vertical, PanelLayout.sectionSpacing)
    }

    private var openConfiguration: some View {
        Button("Настроить \(module.title)", systemImage: "arrow.up.forward") {
            model.navigate(module.page); openWindow(id: "main")
        }.labelStyle(.iconOnly).buttonStyle(.borderless).foregroundStyle(.secondary)
            .font(.caption).frame(width: 28, height: 28).help("Открыть \(module.title)")
    }

    @ViewBuilder private var content: some View {
        @Bindable var model = model
        switch module {
        case .commands, .daemons, .ports:
            ForEach(model.commands.filter { $0.kind == module }) { command in
                HStack(spacing: 6) {
                    Image(systemName: model.scenario == .portOccupied && module == .ports ? "exclamationmark.triangle.fill" : "circle.fill")
                        .font(.system(size: module == .ports && model.scenario == .portOccupied ? 11 : 6))
                        .foregroundStyle(model.scenario == .portOccupied && module == .ports ? Color.orange : command.running ? Color.green : Color.secondary)
                        .frame(width: 12)
                        .accessibilityLabel(command.running ? "Работает" : "Остановлено")
                    Text(command.name).lineLimit(1).layoutPriority(1)
                    Spacer(minLength: 4)
                    Text(module == .ports ? "15432 → 5432" : module == .commands ? command.command : ":\(command.port)")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    Button(command.running ? "Остановить \(command.name)" : "Запустить \(command.name)", systemImage: command.running ? "stop.fill" : "play.fill") {
                        model.toggleCommand(command.id)
                    }.labelStyle(.iconOnly).buttonStyle(.borderless)
                        .frame(width: 24, height: 26)
                        .help(command.running ? "Остановить \(command.name)" : "Запустить \(command.name)")
                        .accessibilityIdentifier("run-\(command.name)")
                }.help(command.command)
            }
            if module == .ports && model.scenario == .portOccupied {
                Text("Порт занят. Откройте подробности.").font(.caption).foregroundStyle(.orange)
            }
        case .chains:
            HStack(spacing: 6) {
                Text("Цепочка среды").lineLimit(1)
                Spacer(minLength: 4)
                Text("3 шага").font(.caption).foregroundStyle(.secondary)
                Button("Запустить цепочку", systemImage: "play.fill") { model.message = "Пример: цепочка запущена." }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).frame(width: 24, height: 26)
            }.help("Colima → minikube → сервисы")
        case .proxy:
            HStack(spacing: 6) {
                Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(model.proxyConnected ? Color.green : Color.secondary).frame(width: 12)
                Text("Прокси VDS")
                Spacer(minLength: 4)
                Text(model.proxyConnected ? "HTTP · :18888" : "Недоступен").font(.caption).foregroundStyle(.secondary)
                Button(model.proxyConnected ? "Отключить прокси" : "Подключить прокси", systemImage: model.proxyConnected ? "stop.fill" : "play.fill") { model.proxyConnected.toggle() }
                    .labelStyle(.iconOnly).buttonStyle(.borderless).frame(width: 24, height: 26)
            }.help(model.proxyConnected ? "HTTP · 127.0.0.1:18888" : "Маршрут недоступен")
        case .sessions:
            HStack {
                Label("3 вкладки сохранены", systemImage: "macwindow.on.rectangle")
                Spacer()
                Text("09:52").font(.caption).foregroundStyle(.secondary)
            }.frame(minHeight: 26)
        case .system:
            PanelMetricRow(title: "CPU", value: "13% · 51°", symbol: "cpu", color: .blue)
            PanelMetricRow(title: "GPU", value: "13% · 51°", symbol: "square.stack.3d.up", color: .purple)
            PanelMetricRow(title: "Память", value: "35,6 / 48 ГБ", symbol: "memorychip", color: .green)
            PanelMetricRow(title: "Своп", value: "9,4 ГБ", symbol: "arrow.triangle.swap")
            PanelMetricRow(title: "Диск", value: "636 / 995 ГБ", symbol: "internaldrive", color: .orange)
            PanelMetricRow(title: "Время работы", value: "48 д 23 ч", symbol: "clock")
        case .containers:
            PanelMetricRow(title: "Colima RAM", value: "6,2 / 12 ГБ", symbol: "memorychip", color: .blue)
            PanelMetricRow(title: "minikube RAM", value: "3,4 / 8 ГБ", symbol: "memorychip", color: .purple)
            PanelMetricRow(title: "Диск VM", value: "40 / 98 ГБ", symbol: "internaldrive", color: .orange)
            PanelMetricRow(title: "Кластер", value: "В норме", symbol: "checkmark.circle", color: .green)
        case .traffic:
            PanelMetricRow(title: "Wi-Fi", value: "en0", symbol: "wifi", color: .blue)
            PanelMetricRow(title: "Получение", value: "↓ 962 КБ/с", symbol: "arrow.down", color: .cyan)
            PanelMetricRow(title: "Отправка", value: "↑ 27 КБ/с", symbol: "arrow.up", color: .purple)
            Text("Включая локальную сеть").font(.caption).foregroundStyle(.secondary).padding(.top, 2)
        case .energy:
            PanelMetricRow(title: "Батарея", value: "99% · зарядка", symbol: "battery.100percent", color: .green)
            PanelMetricRow(title: "Состояние", value: "100% · 75 циклов", symbol: "heart", color: .red)
            PanelMetricRow(title: "Адаптер", value: "90 Вт", symbol: "bolt", color: .orange)
            PanelMetricRow(title: "Заряд", value: "+17 Вт", symbol: "battery.100percent.bolt", color: .green)
            Divider().padding(.vertical, 3)
            Text("Последний разряд · доли расхода").font(.caption).foregroundStyle(.secondary)
            PanelMetricRow(title: "Ghostty", value: "38%", symbol: "terminal")
            PanelMetricRow(title: "Docker / Colima", value: "27%", symbol: "shippingbox")
        case .brightness:
            ForEach(model.displays) { display in PanelBrightnessRow(display: display) }
            HStack {
                Text("Связать яркость")
                Spacer()
                Toggle("Связать яркость", isOn: $model.linkedSliders)
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }.padding(.top, 4)
        case .awake:
            HStack(spacing: 8) {
                Label("Не засыпать", systemImage: "moon")
                Spacer(minLength: 8)
                Picker("Длительность", selection: $model.awakeDuration) {
                    ForEach(["30 минут", "1 час", "2 часа", "Без срока"], id: \.self) { Text($0) }
                }.labelsHidden().controlSize(.small).fixedSize()
                Toggle("Не засыпать", isOn: $model.awake).labelsHidden().toggleStyle(.switch).controlSize(.small)
            }.help("Работа с закрытой крышкой. В приложении при включении потребуется Touch ID или пароль.")
        case .clipboard:
            TextField("Найти скопированное", text: $model.query)
                .textFieldStyle(.roundedBorder).accessibilityIdentifier("panel-clip-search")
            if model.filteredClips.isEmpty {
                Text(model.query.isEmpty ? "История пуста" : "Ничего не найдено")
                    .foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.filteredClips) { clip in
                        HStack(spacing: 4) {
                            Button { model.copy(clip) } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: clip.kind.symbol).foregroundStyle(.secondary).frame(width: 16)
                                    Text(clip.content).lineLimit(1).truncationMode(.tail)
                                    Spacer(minLength: 0)
                                }.frame(maxWidth: .infinity, alignment: .leading).frame(minHeight: 32).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .help("Скопировать · \(clip.source) · \(clip.time)\n\(clip.content)")
                                .accessibilityLabel("Скопировать: \(clip.content), \(clip.source)")
                            Button(clip.pinned ? "Открепить" : "Закрепить", systemImage: clip.pinned ? "pin.fill" : "pin") { model.togglePin(clip.id) }
                                .labelStyle(.iconOnly).buttonStyle(.borderless)
                                .foregroundStyle(clip.pinned ? Color.accentColor : Color.secondary)
                                .frame(width: 28, height: 32).help(clip.pinned ? "Открепить" : "Закрепить")
                        }
                        if clip.id != model.filteredClips.last?.id { Divider() }
                    }
                }
            }
        }
    }
}

private struct PanelMetricRow: View {
    let title: String
    let value: String
    let symbol: String
    var color: Color = .secondary
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 16)
            Text(title).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(.secondary).lineLimit(1)
        }.frame(minHeight: 24).accessibilityElement(children: .combine)
    }
}

private struct PanelBrightnessRow: View {
    @Environment(PrototypeModel.self) private var model
    let display: DemoDisplay
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: display.symbol).foregroundStyle(.secondary).frame(width: 16)
                Text(display.name).lineLimit(1)
                Spacer(minLength: 8)
                Text(model.isConnected(display) ? "\(Int(display.brightness))%" : "Отключён")
                    .monospacedDigit().foregroundStyle(.secondary)
                    .frame(minWidth: 36, alignment: .trailing)
            }
            HStack(spacing: 8) {
                Image(systemName: "sun.min").foregroundStyle(.secondary).frame(width: 16)
                Slider(value: Binding(
                    get: { model.displays.first { $0.id == display.id }?.brightness ?? display.brightness },
                    set: { model.setBrightness(display.id, to: $0) }
                ), in: 0...100)
                    .controlSize(.regular)
                    .accessibilityLabel("Яркость \(display.name)")
                    .accessibilityValue("\(Int(display.brightness)) процентов")
                    .accessibilityIdentifier("brightness-\(display.id)")
                Image(systemName: "sun.max").foregroundStyle(.secondary).frame(width: 16)
            }.disabled(!model.isConnected(display))
        }.padding(.vertical, 4)
            .help(model.isConnected(display) ? display.subtitle : "Монитор отключён")
    }
}

struct PrototypePanelWindow: View {
    var body: some View {
        PrototypePanel()
    }
}
