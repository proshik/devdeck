import SwiftUI

struct DisplaysPage: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                HStack(spacing: 24) {
                    ForEach(model.displays) { display in
                        VStack(spacing: 8) {
                            Image(systemName: display.symbol).font(.system(size: 36))
                            Text(display.name).font(.callout)
                            Text(model.cursorDisplay == display.id ? "Под курсором" : display.subtitle)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .foregroundStyle(model.cursorDisplay == display.id ? Color.accentColor : Color.secondary)
                        .opacity(model.isConnected(display) ? 1 : 0.4)
                        .onContinuousHover { phase in
                            if case .active = phase, model.isConnected(display) { model.cursorDisplay = display.id }
                        }
                        .onTapGesture { model.cursorDisplay = display.id }
                        .accessibilityLabel("\(display.name). Выбрать экран под курсором в макете")
                        .accessibilityAddTraits(.isButton)
                        .accessibilityAction { model.cursorDisplay = display.id }
                    }
                }.padding(.vertical, 12)
            } header: { Text("Расположение экранов") }
            footer: { Text("Мониторы демонстрационные. Наведите курсор на изображение, чтобы выбрать экран для проверки клавиш.") }

            Section {
                Toggle("Штатные клавиши яркости MacBook", isOn: $model.nativeKeys)
                    .accessibilityIdentifier("native-brightness-keys")
                LabeledContent("Какой экран менять", value: "Экран под курсором")
                Toggle("Применять связь ползунков к клавишам", isOn: $model.linkedKeys)
                    .disabled(!model.linkedSliders || !model.nativeKeys)
            } header: { Text("Клавиатура") }
            footer: {
                Text("В готовой функции клавиши работают и при закрытой панели. По умолчанию каждое нажатие меняет только экран под курсором.")
            }

            Section("Яркость мониторов") {
                ForEach(model.displays) { display in
                    DisplayBrightnessRow(display: display)
                }
                Toggle("Связать ползунки яркости", isOn: $model.linkedSliders)
            }

            Section {
                BrightnessKeyDemo()
            } header: { Text("Проверка сценария в прототипе") }
            footer: {
                Text("Кнопки ниже имитируют штатные клавиши. Прототип не перехватывает клавиатуру и не изменяет яркость подключённых мониторов.")
            }

            Section("Способ управления — предложение") {
                LabeledContent("Первый вариант", value: "Интеграция с BetterDisplay")
                Text("BetterDisplay управляет мониторами и обрабатывает штатные клавиши. DevDeck показывает значения и даёт быстрые действия. Второй обработчик клавиш одновременно не включается.")
                    .foregroundStyle(.secondary)
                DisclosureGroup("Альтернатива: самостоятельное управление") {
                    Text("Отдельные провайдеры для встроенного экрана, DDC/CI и программного затемнения. До реализации нужно проверить совместимость мониторов и доков. Программное затемнение не равно изменению мощности подсветки.")
                        .foregroundStyle(.secondary)
                }
            }
        }.formStyle(.grouped)
    }
}

struct DisplayBrightnessRow: View {
    @Environment(PrototypeModel.self) private var model
    let display: DemoDisplay
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(display.name)
                        Text(model.isConnected(display) ? display.subtitle : "Монитор отключён")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: display.symbol).imageScale(.large).frame(width: 30) }
                Spacer()
                Text("\(Int(display.brightness))%").monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Image(systemName: "sun.min").foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { model.displays.first { $0.id == display.id }?.brightness ?? display.brightness },
                    set: { model.setBrightness(display.id, to: $0) }
                ), in: 0...100)
                .accessibilityLabel("Яркость \(display.name)")
                .accessibilityIdentifier("brightness-\(display.id)")
                Image(systemName: "sun.max").foregroundStyle(.secondary)
            }
            .disabled(!model.isConnected(display))
        }.padding(.vertical, 5)
    }
}

struct BrightnessKeyDemo: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        @Bindable var model = model
        VStack(alignment: .leading, spacing: 12) {
            Picker("Курсор на экране", selection: $model.cursorDisplay) {
                ForEach(model.displays) { Text($0.name).tag($0.id) }
            }
            HStack {
                Button("Яркость −", systemImage: "sun.min") { model.brightnessKey(-6.25) }
                    .accessibilityIdentifier("brightness-key-down")
                Button("Яркость +", systemImage: "sun.max") { model.brightnessKey(6.25) }
                    .accessibilityIdentifier("brightness-key-up")
                Spacer()
                if let display = model.displays.first(where: { $0.id == model.cursorDisplay }) {
                    Text("\(Int(display.brightness))%").monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }
}

#Preview("Экраны · стандартные формы") {
    DisplaysPage().environment(PrototypeModel()).frame(width: 760, height: 850)
}
