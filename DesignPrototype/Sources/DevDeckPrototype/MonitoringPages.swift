import SwiftUI
import Charts

struct MetricRow: View {
    let title: String
    let value: String
    let symbol: String
    var color: Color = .secondary
    var body: some View {
        HStack {
            Image(systemName: symbol).foregroundStyle(color).frame(width: 20)
            Text(title)
            Spacer(minLength: 8)
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }
}

struct MetricChart: View {
    var color: Color = .accentColor
    private let values: [Double] = [9, 11, 10, 14, 12, 16, 13, 19, 15, 16, 12, 15, 20, 17, 18, 14, 17, 16, 21, 18, 13]
    var body: some View {
        Chart(Array(values.enumerated()), id: \.offset) { sample in
            LineMark(x: .value("Время", sample.offset), y: .value("Нагрузка", sample.element))
                .foregroundStyle(color).interpolationMethod(.linear)
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...30)
        .frame(height: 65)
        .accessibilityLabel("Демонстрационный график за последние пять минут")
    }
}

struct MonitoringPage: View {
    @Environment(PrototypeModel.self) private var model
    var body: some View {
        @Bindable var model = model
        Form {
            Section("Этот Mac") {
                MetricRow(title: "CPU", value: "13% · 51 °C", symbol: "cpu", color: .blue)
                MetricChart()
                MetricRow(title: "GPU", value: "13% · 51 °C", symbol: "square.stack.3d.up", color: .purple)
                MetricRow(title: "Память", value: "35,6 / 48 ГБ", symbol: "memorychip", color: .green)
                MetricRow(title: "Своп", value: "9,4 ГБ", symbol: "arrow.triangle.swap")
                MetricRow(title: "Диск", value: "636 / 995 ГБ", symbol: "internaldrive", color: .orange)
                MetricRow(title: "Время работы", value: "48 дней 23 часа", symbol: "clock")
            }
            Section("Контейнеры") {
                MetricRow(title: "Colima · память", value: "6,2 / 12 ГБ", symbol: "memorychip", color: .blue)
                MetricRow(title: "minikube · память", value: "3,4 / 8 ГБ", symbol: "memorychip", color: .purple)
                MetricRow(title: "Диск VM", value: "40 / 98 ГБ", symbol: "internaldrive")
                LabeledContent("Кластер", value: "В норме")
                Button("Открыть очистку контейнеров") { model.navigate(.cleanup) }
            }
            Section {
                Toggle("Собирать историю показателей", isOn: $model.monitoringHistory)
                Text("Предложение: частый опрос при открытой панели и редкий в фоне. Если показатель недоступен на этом Mac, показывать причину вместо нуля.")
                    .foregroundStyle(.secondary)
            } header: { Text("Сбор показателей") }
            footer: { Text("Числа и график в прототипе статические. Показатели Mac и контейнеров считаются отдельно.") }
        }.formStyle(.grouped)
    }
}

struct TrafficPage: View {
    @Environment(PrototypeModel.self) private var model
    @State private var interface = "Wi-Fi · en0"
    @State private var result = "Ещё не проверяли"
    var body: some View {
        Form {
            Section("Трафик интерфейса") {
                Picker("Интерфейс", selection: $interface) {
                    Text("Wi-Fi · en0").tag("Wi-Fi · en0")
                    Text("Ethernet · en5").tag("Ethernet · en5")
                }
                MetricRow(title: "Получение", value: "962 КБ/с", symbol: "arrow.down", color: .cyan)
                MetricRow(title: "Отправка", value: "27 КБ/с", symbol: "arrow.up", color: .purple)
                MetricChart(color: .cyan)
                LabeledContent("Получено за сеанс", value: "3,8 ГБ")
                LabeledContent("Отправлено за сеанс", value: "420 МБ")
                Text("Счётчики интерфейса включают локальную сеть. Они не измеряют пропускную способность интернета.")
                    .foregroundStyle(.secondary)
            }
            Section {
                LabeledContent("Последний результат", value: result)
                Button("Проверить интернет") { result = "420 Мбит/с ↓ · 95 Мбит/с ↑ (пример)" }
            } header: { Text("Отдельная проверка интернета") }
            footer: { Text("В готовой функции тест запускается по запросу. Прототип не отправляет трафик в сеть.") }
        }.formStyle(.grouped)
    }
}

struct EnergyPage: View {
    var body: some View {
        Form {
            Section("Питание") {
                MetricRow(title: "Батарея", value: "99% · зарядка", symbol: "battery.100percent", color: .green)
                MetricRow(title: "Состояние батареи", value: "100% · 75 циклов", symbol: "heart", color: .red)
                MetricRow(title: "Адаптер", value: "90 Вт", symbol: "bolt", color: .orange)
                MetricRow(title: "Мощность заряда", value: "+17 Вт", symbol: "battery.100percent.bolt", color: .green)
            }
            Section {
                MetricRow(title: "Ghostty", value: "38%", symbol: "terminal")
                MetricRow(title: "Docker / Colima", value: "27%", symbol: "shippingbox")
                MetricRow(title: "Другие приложения", value: "35%", symbol: "app")
            } header: { Text("Доля учтённого расхода · последний разряд") }
            footer: { Text("Развиваем существующий учёт расхода батареи. Это доли учтённого расхода приложений, а не проценты заряда или точная мощность каждого процесса.") }
        }.formStyle(.grouped)
    }
}
