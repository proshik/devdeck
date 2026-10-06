import SwiftUI

struct GeneralSettingsPage: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("Язык и оформление") {
                Picker("Язык интерфейса", selection: $model.interfaceLanguage) {
                    Text("Русский").tag("Русский")
                    Text("English").tag("English")
                }
                .onChange(of: model.interfaceLanguage) { _, value in
                    model.message = "Пример выбора языка: \(value). Тексты макета пока на русском."
                }
                Picker("Тема", selection: $model.appearance) {
                    ForEach(DemoAppearance.allCases) { Text($0.title).tag($0) }
                }.pickerStyle(.segmented)
            }
            Section("Запуск") {
                Toggle("Запускать DevDeck при входе в систему", isOn: $model.launchAtLogin)
                Toggle("Открывать панель сочетанием ⌃⌥D", isOn: $model.globalHotkey)
            }
            Section("Панель") {
                Button("Настроить панель и модули…") { model.navigate(.layout) }
            }
            Section("О DevDeck") {
                LabeledContent("Версия DevDeck", value: "0.22.1 (пример)")
                Button("Обновления DevDeck…") { model.navigate(.updates) }
            }
        }.formStyle(.grouped)
    }
}

struct PermissionsPage: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        Form {
            Section("Буфер обмена") {
                LabeledContent("История и копирование", value: "Доступно")
                LabeledContent("Вставка в другое приложение", value: model.scenario == .pastePermission ? "Нужен Универсальный доступ" : model.pasteEnabled ? "Доступно (пример)" : "Не включена")
                Button("Разрешить вставку") {
                    model.message = "Пример: переход в настройки Универсального доступа. Системные настройки не открываются."
                }
            }
            Section("Экраны и сон") {
                LabeledContent("Управление яркостью", value: "Через выбранный провайдер")
                LabeledContent("Работа с закрытой крышкой", value: "Touch ID или пароль при включении")
                Text("Права для обработки клавиш зависят от выбранного провайдера. При интеграции яркостью и штатными клавишами управляет BetterDisplay.")
                    .foregroundStyle(.secondary)
            }
            Section("Сессии агентов") {
                LabeledContent("Чтение вкладок Ghostty", value: "Автоматизация приложения")
                LabeledContent("Состояния в этом окне", value: "Демонстрационные")
            }
        }.formStyle(.grouped)
    }
}

struct AutomationPage: View {
    @Environment(PrototypeModel.self) private var model
    @State private var enabled = false
    var body: some View {
        Form {
            Section {
                Toggle("Разрешить локальные команды автоматизации", isOn: $enabled)
                Text("Следующий этап: внешние инструменты вызывают сохранённые команды по UUID и получают состояние запроса. Произвольная строка запуска не передаётся.")
                    .foregroundStyle(.secondary)
                LabeledContent("Статус функции", value: "Предложение, не реализовано")
            } header: { Text("Локальная автоматизация") }
            Section {
                Text("Обычная работа с командами, цепочками, портами и прокси остаётся в разделе «Среда разработки».")
                Button("Открыть команды") { model.navigate(.commands) }
            }
        }.formStyle(.grouped)
    }
}

struct UpdatesPage: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            if model.scenario == .recovery {
                Section {
                    Label("Режим восстановления", systemImage: "exclamationmark.shield").foregroundStyle(.orange)
                    Text("После повторных ошибок оставляем доступ к конфигурации, диагностике и обновлениям. Конфигурация и снимки сессий сохранены.")
                    Button("Попробовать обычный запуск") { model.applyScenario(.normal) }
                } footer: { Text("Защита от цикла падений — предложение для следующего этапа.") }
            }
            Section("Обновление приложения") {
                LabeledContent("Версия DevDeck", value: "0.22.1 (пример)")
                Label("Установлена актуальная версия (пример)", systemImage: "checkmark.circle")
                    .foregroundStyle(.secondary)
                Button("Проверить обновления") { model.message = "Пример: новая версия не найдена. Запросы не отправляются." }
            }
            Section {
                Toggle("Автоматически скачивать и устанавливать обновления", isOn: $model.automaticUpdates)
            } header: { Text("Автообновление DevDeck") }
            footer: { Text("Если выключено, DevDeck проверяет новые версии и предлагает установку вручную.") }
            Section("Перезапуск — предложение") {
                Text("Предлагать установку после завершения команд, цепочек и восстановления вкладок. Долгоживущие прокси и фоновые процессы учитывать отдельно.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

#Preview("Общие настройки") {
    GeneralSettingsPage().environment(PrototypeModel()).frame(width: 740, height: 650)
}

#Preview("Обновления DevDeck") {
    UpdatesPage().environment(PrototypeModel()).frame(width: 740, height: 650)
}
