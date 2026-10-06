import SwiftUI

struct ClipboardPage: View {
    @Environment(PrototypeModel.self) private var model
    @State private var settings = false
    @State private var confirmClear = false
    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            Picker("Буфер обмена", selection: $settings) {
                Text("История").tag(false)
                Text("Настройки").tag(true)
            }.pickerStyle(.segmented).fixedSize().padding()
            if settings { preferences }
            else {
                HStack {
                    Text("\(model.clips.count) записей").foregroundStyle(.secondary)
                    Spacer()
                    Button(model.recording ? "Приостановить запись" : "Продолжить запись") { model.recording.toggle() }
                    Button("Очистить…", systemImage: "trash") { confirmClear = true }
                }.padding(.horizontal).padding(.bottom, 12)
                ClipFilterPicker().padding(.horizontal).padding(.bottom, 12)
                HSplitView {
                    List(selection: $model.selectedClip) {
                        ForEach(model.filteredClips) { clip in
                            ClipSummary(clip: clip).tag(clip.id)
                                .contextMenu {
                                    Button("Скопировать") { model.copy(clip) }
                                    Button(clip.pinned ? "Открепить" : "Закрепить") { model.togglePin(clip.id) }
                                    Button("Удалить", role: .destructive) { remove(clip.id) }
                                }
                        }
                    }
                    .frame(minWidth: 250, idealWidth: 320)
                    .overlay { if model.filteredClips.isEmpty { ClipboardEmptyState() } }
                    clipDetail.frame(minWidth: 260, maxWidth: .infinity, maxHeight: .infinity)
                }
                .searchable(text: $model.query, prompt: "Поиск по тексту или приложению")
            }
        }
        .onChange(of: model.query) { _, _ in selectVisibleClip() }
        .onChange(of: model.clipFilter) { _, _ in selectVisibleClip() }
        .confirmationDialog("Удалить незакреплённые записи?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Удалить незакреплённые", role: .destructive) {
                model.clips.removeAll { !$0.pinned }
                model.selectedClip = model.clips.first?.id
            }
        } message: { Text("Закреплённые записи сохранятся. Это действие относится только к примерам в прототипе.") }
    }

    @ViewBuilder private var clipDetail: some View {
        if let clip = model.filteredClips.first(where: { $0.id == model.selectedClip }) {
            VStack(alignment: .leading, spacing: 20) {
                HStack {
                    Text(clip.source).foregroundStyle(.secondary)
                    Spacer()
                    Button(clip.pinned ? "Открепить" : "Закрепить", systemImage: clip.pinned ? "pin.fill" : "pin") {
                        model.togglePin(clip.id)
                    }.labelStyle(.iconOnly)
                }
                if clip.kind == .image {
                    ContentUnavailableView("Пример изображения", systemImage: "photo", description: Text(clip.content))
                } else {
                    ScrollView {
                        Text(clip.content).font(clip.kind == .text ? .system(.body, design: .monospaced) : .body)
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding()
                    }.background(.quaternary, in: RoundedRectangle(cornerRadius: 8)).frame(minHeight: 130)
                }
                HStack {
                    Button("Скопировать") { model.copy(clip) }.buttonStyle(.borderedProminent)
                    if model.pasteEnabled { Button("Вставить") { paste(clip) } }
                    Button("Удалить", systemImage: "trash", role: .destructive) { remove(clip.id) }
                        .labelStyle(.iconOnly)
                }
                if model.scenario == .pastePermission {
                    Label("Копирование доступно. Для вставки нужен Универсальный доступ.", systemImage: "lock.shield")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Открыть разрешения") { model.navigate(.permissions) }
                }
                Spacer(minLength: 0)
                Text("Содержимое — пример. Копирование и вставка не меняют системный буфер.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        } else {
            ContentUnavailableView("Выберите запись", systemImage: "clipboard", description: Text("Содержимое и действия появятся здесь."))
        }
    }

    private var preferences: some View {
        @Bindable var model = model
        return Form {
            Section {
                Toggle("Записывать историю", isOn: $model.recording)
                Picker("Количество записей", selection: $model.clipLimit) {
                    Text("50").tag(50); Text("100").tag(100); Text("300").tag(300)
                }
                Picker("Хранить незакреплённые", selection: $model.retention) {
                    ForEach(["1 день", "7 дней", "30 дней"], id: \.self) { Text($0) }
                }
                LabeledContent("Закреплённые записи", value: "До удаления пользователем")
            } header: { Text("История") }
            footer: { Text("Предлагаемые ограничения: 100 записей, 7 дней, изображения до 10 МБ. Срок хранения и лимиты показаны как настройки дизайна и пока не применяются к примерам.") }
            Section {
                Toggle("Разрешить вставку в предыдущее приложение", isOn: $model.pasteEnabled)
                Text("Копирование доступно без Универсального доступа. Разрешение запрашивается отдельно, когда пользователь включает вставку.")
                    .foregroundStyle(.secondary)
            } header: { Text("Вставка") }
            Section {
                TextEditor(text: $model.exclusions).frame(height: 75).font(.body)
                    .accessibilityLabel("Исключённые приложения")
            } header: { Text("Не записывать из приложений") }
            footer: { Text("Явные исключения и отметки конфиденциальности. Не обещаем распознать каждый пароль в обычном тексте. История хранится локально; файлы сохраняются как ссылки.") }
            Section { Button("Очистить незакреплённые записи…", role: .destructive) { confirmClear = true } }
        }.formStyle(.grouped)
    }
    private func remove(_ id: Int) {
        model.clips.removeAll { $0.id == id }
        if model.selectedClip == id { model.selectedClip = model.filteredClips.first?.id }
    }
    private func selectVisibleClip() {
        if !model.filteredClips.contains(where: { $0.id == model.selectedClip }) {
            model.selectedClip = model.filteredClips.first?.id
        }
    }
    private func paste(_ clip: DemoClip) {
        if model.scenario == .pastePermission { model.navigate(.permissions) }
        else { model.message = "Пример: запись вставлена в предыдущее приложение. Системный буфер не изменён." }
    }
}

struct ClipFilterPicker: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Picker("Тип записи", selection: $model.clipFilter) {
            ForEach(["Все", "Текст", "Изображения", "Файлы", "Закреплённые"], id: \.self) { Text($0) }
        }.pickerStyle(.segmented).labelsHidden()
    }
}

struct ClipSummary: View {
    let clip: DemoClip
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: clip.kind.symbol).foregroundStyle(.secondary).frame(width: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(clip.content).lineLimit(2)
                Text("\(clip.source) · \(clip.time)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if clip.pinned { Image(systemName: "pin.fill").font(.caption).foregroundStyle(.tint) }
        }.padding(.vertical, 4)
    }
}

struct ClipboardEmptyState: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        ContentUnavailableView(
            model.query.isEmpty ? "История пока пуста" : "Ничего не найдено",
            systemImage: model.query.isEmpty ? "clipboard" : "magnifyingglass",
            description: Text(model.query.isEmpty ? "После включения истории скопированные записи появятся здесь." : "Измените запрос или выберите другой тип записи.")
        )
    }
}
