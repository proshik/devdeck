import SwiftUI

struct CommandsPage: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        @Bindable var model = model
        HSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selectedCommand) {
                    ForEach([DeckModule.commands, .daemons]) { kind in
                        Section(kind.title) {
                            ForEach(model.commands.filter { $0.kind == kind }) { command in
                                HStack {
                                    Label(command.name, systemImage: kind.symbol)
                                    Spacer()
                                    if command.running { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(.green) }
                                }.tag(command.id)
                            }
                        }
                    }
                    Section("Цепочки") {
                        Label("Полный запуск среды", systemImage: "link")
                            .contextMenu { Button("Запустить") { model.message = "Пример: Colima → minikube → сервисы." } }
                    }
                }
                HStack {
                    Button("Добавить команду", systemImage: "plus") {
                        let command = DemoCommand(name: "Новая команда", command: "just status", kind: .commands)
                        model.commands.append(command); model.selectedCommand = command.id
                    }
                    Spacer()
                }.padding(12).background(.bar)
            }.frame(minWidth: 210, idealWidth: 250)
            if let index = model.commands.firstIndex(where: { $0.id == model.selectedCommand }) {
                CommandEditor(index: index).frame(minWidth: 360)
            } else {
                ContentUnavailableView("Выберите команду", systemImage: "terminal")
            }
        }
    }
}

private struct CommandEditor: View {
    @Environment(PrototypeModel.self) private var model
    let index: Int
    var body: some View {
        @Bindable var model = model
        Form {
            Section("Команда") {
                TextField("Название", text: $model.commands[index].name)
                TextField("Запуск", text: $model.commands[index].command).font(.system(.body, design: .monospaced))
                TextField("Рабочая папка", text: $model.commands[index].directory)
                Toggle("Перезапускать при остановке", isOn: $model.commands[index].watchdog)
                Toggle("Направлять через прокси", isOn: $model.commands[index].proxy)
                HStack {
                    Label(model.commands[index].running ? "Работает" : "Остановлена", systemImage: "circle.fill")
                        .foregroundStyle(model.commands[index].running ? Color.green : Color.secondary)
                    Spacer()
                    Button(model.commands[index].running ? "Остановить" : "Запустить") {
                        model.toggleCommand(model.commands[index].id)
                    }.buttonStyle(.borderedProminent)
                }
            }
            Section("Последний вывод — пример") {
                Text("$ \(model.commands[index].command)\n[10:12:04] Проверка зависимостей…\n[10:12:05] Готово\n[10:12:05] \(model.commands[index].running ? "Процесс работает" : "Ожидание запуска")")
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            }
            Section("Цепочка «Полный запуск среды»") {
                LabeledContent("1", value: "Colima")
                LabeledContent("2", value: "minikube")
                LabeledContent("3", value: "Сервисы проекта")
                Button("Запустить цепочку") { model.message = "Пример: последовательный запуск Colima → minikube → сервисы." }
            }
        }.formStyle(.grouped)
    }
}

struct PortsPage: View {
    @Environment(PrototypeModel.self) private var model
    @State private var confirmOccupant = false
    var body: some View {
        Form {
            if model.scenario == .portOccupied {
                Section {
                    Label("Порт 15432 занят", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    LabeledContent("Процесс", value: "kubectl · PID 4821 (пример)")
                    HStack {
                        Button("Завершить процесс…", role: .destructive) { confirmOccupant = true }
                        Button("Изменить порт") { model.message = "Пример: открыть редактор команды PostgreSQL." }
                    }
                } footer: { Text("Показываем владельца порта до запуска. Процесс не завершается автоматически.") }
            }
            Section("Пробросы") {
                ForEach(model.commands.filter { $0.kind == .ports }) { command in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(command.name)
                            Text("127.0.0.1:15432 → svc/postgres:5432").font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button(command.running ? "Остановить" : "Запустить") { model.toggleCommand(command.id) }
                    }
                }
            }
            Section("Наблюдение за процессом") {
                LabeledContent("Watchdog", value: "Включён")
                LabeledContent("После перезапуска DevDeck", value: "Подхватить живой процесс")
                Text("Проброс — существующая фоновая команда. Логи, запуск и восстановление используют общий механизм DevDeck.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .confirmationDialog("Завершить kubectl, PID 4821?", isPresented: $confirmOccupant, titleVisibility: .visible) {
            Button("Завершить пример процесса", role: .destructive) {
                model.applyScenario(.normal); model.message = "Пример конфликта разрешён. Реальные процессы не изменены."
            }
        } message: { Text("Это может прервать другой проброс. В прототипе изменится только демонстрационное состояние.") }
    }
}

struct ProxyPage: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("Маршрут для команд") {
                Toggle("Использовать VDS", isOn: $model.proxyConnected)
                LabeledContent("Источник", value: "SSH-туннель → HTTP-мост")
                LabeledContent("Локальный адрес", value: "http://127.0.0.1:18888")
                HStack {
                    Button("Проверить маршрут") { model.message = "Пример: запрос через VDS выполнен успешно." }
                    Button("Открыть браузер через прокси") { model.message = "Пример: отдельный браузер с маршрутом через прокси." }
                }.disabled(!model.proxyConnected)
            }
            Section {
                Toggle("Раздавать прокси в локальной сети", isOn: $model.sharingProxy)
                Picker("Движок", selection: $model.proxyEngine) {
                    Text("Встроенный").tag("Встроенный"); Text("gost").tag("gost")
                }
                LabeledContent("Адрес сервера", value: "Этот Mac · порт 18889")
                LabeledContent("Обнаружение", value: "Bonjour")
            } header: { Text("Раздача прокси") }
            footer: { Text("Пароли остаются в Keychain. В прототипе нет соединений, слушателей или доступа к сохранённым учётным данным.") }
            Section("Поведение при недоступном маршруте") {
                Text("Команды с включённым маршрутом через прокси показывают ошибку. Прямое соединение без прокси не включается автоматически.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct AwakePage: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Работать с закрытой крышкой", isOn: $model.awake)
                Picker("Длительность", selection: $model.awakeDuration) {
                    ForEach(["30 минут", "1 час", "2 часа", "Без срока"], id: \.self) { Text($0) }
                }
                LabeledContent("Состояние", value: model.awake ? "Активно · \(model.awakeDuration)" : "Обычный режим сна")
            } header: { Text("Сон и крышка") }
            footer: { Text("Функция уже есть в DevDeck 0.22.1. При включении готовое приложение использует Touch ID или пароль; прототип только показывает состояние.") }
            Section("Восстановление") {
                Label("Исходные настройки сна восстанавливаются при завершении режима", systemImage: "arrow.uturn.backward")
                Text("Защита по температуре и батарее остаётся в существующем AwakeModel. Перенос блока в другую вкладку не меняет его работу.")
                    .foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct SessionsPage: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("Восстановление вкладок") {
                Toggle("Сохранять сессии агентов", isOn: $model.restoreSessions)
                LabeledContent("Последний снимок", value: "6 октября, 09:52 · 3 вкладки")
                Button("Сохранить снимок") { model.message = "Пример: сохранены 3 вкладки. Реальные снимки не изменены." }
            }
            Section("Сессии в Ghostty — примеры") {
                ForEach(["Claude Code · DevDeck", "opencode · API", "Claude Code · UI"], id: \.self) { title in
                    HStack {
                        Label(title, systemImage: "terminal")
                        Spacer()
                        Button("Открыть") { model.message = "Пример: открыть \(title)." }
                    }
                }
            }
            Section { Text("Снимок предыдущей загрузки не заменяется, пока восстановление не разрешено. Здесь отображается существующая функция DevDeck.").foregroundStyle(.secondary) }
        }.formStyle(.grouped)
    }
}

struct CleanupPage: View {
    @Environment(PrototypeModel.self) private var model
    @State private var confirm = false
    var body: some View {
        Form {
            Section("Colima · использование диска") {
                LabeledContent("Образы", value: "12,1 ГБ")
                LabeledContent("Кеш сборки", value: "6,3 ГБ")
                LabeledContent("Можно освободить", value: model.cleanupSize)
                Button("Очистить кеш сборки…") { confirm = true }
            }
            Section { Text("Перед очисткой показываем состав. Томам и пользовательским данным нужны отдельные действия и подтверждение.").foregroundStyle(.secondary) }
        }.formStyle(.grouped)
        .confirmationDialog("Очистить 6,3 ГБ кеша сборки?", isPresented: $confirm, titleVisibility: .visible) {
            Button("Очистить пример кеша", role: .destructive) { model.cleanupSize = "12,1 ГБ"; model.message = "Пример кеша очищен. Docker и Colima не изменены." }
        } message: { Text("Образы и тома сохранятся. В прототипе меняются только числа.") }
    }
}
