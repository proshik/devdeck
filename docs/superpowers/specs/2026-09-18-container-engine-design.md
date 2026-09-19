# Движок контейнеров как абстракция: colima и Docker Desktop, индикатор в трее, нейминг

Дата: 2026-09-18. Статус: дизайн утверждён, план написан
(`docs/superpowers/plans/2026-09-18-container-engine.md`), реализация не начата.
Объём: первый из трёх кусков (см. «Что сюда не входит»).

## Зачем

Две причины, пришедшие вместе.

1. Хочется видеть в меню-баре, запущена ли colima, не открывая попап. Сейчас это знает только
   `LiveClusterHealthProbe`, и опрашивается он лишь пока попап открыт.
2. DevDeck целиком зашит на colima: `colima ssh`, `colima list --json`, подпись «VM colima»,
   кнопка «Перезапустить colima». На машине с Docker Desktop половина интерфейса показывает
   пустоту, и непонятно, почему.

Разговор начался с расхода батареи, поэтому цена опроса — не деталь, а требование: индикатор
не должен стоить ни одного подпроцесса.

## Что выяснилось про Docker Desktop (исследование 2026-09-17)

Существенное для этого дизайна:

- Состояние движка снимается без подпроцессов: приложение с bundle id `com.docker.docker`
  в списке запущенных плюс `connect()` к `~/.docker/run/docker.sock`. `docker desktop status
  --format json` (с 4.39) стоит запуска процесса — для таймера не годится.
- Память внутри VM (`MemTotal − MemAvailable`) достаётся только запуском контейнера:
  `docker run --rm --entrypoint cat alpine /proc/meminfo` (привилегий не требует, `/proc/meminfo`
  не изолирован). Но Resource Saver гасит VM через ~5 минут простоя, а `docker run` её будит на
  3–10 секунд и возвращает в память пару гигабайт. **Опрашивать память Docker Desktop по таймеру
  нельзя** — это ломает ровно ту экономию, ради которой всё затевалось.
- Диск: аллоцированный размер `Docker.raw` читается одним `stat`, без docker и даже на
  остановленном движке. Путь берётся из `DataFolder`, а не хардкодится.
- Лимиты: `docker info` (`NCPU`, `MemTotal`). Файл `settings-store.json` парсить не стоит:
  недокументирован, переименован в 4.35, ключи сменили регистр, хранит только изменённые значения.
- Перезапуск: `docker desktop restart`, синхронный, с 4.39.

Из этого следует главный вывод дизайна: **набор доступных метрик у движков разный, и абстракция
не должна это скрывать**. Ячейка, которой у движка нет, не показывается.

## Изменение 1 — протокол движка

Новая папка `DevDeck/Engine/`, файл `ContainerEngine.swift`:

```swift
enum ContainerEngineKind: String, Codable, CaseIterable, Sendable { case colima, dockerDesktop }

protocol ContainerEngine: Sendable {
    var kind: ContainerEngineKind { get }
    var displayName: String { get }   // "colima" / "Docker Desktop"
    func isInstalled() -> Bool
    func isRunning() -> Bool
}
```

(`wrap` в протокол в этом куске не входит — см. «Уточнения при планировании».)

`isRunning()` обязан укладываться в микросекунды и не запускать процессов — он вызывается
каждые 2 секунды из таймера трея.

### ColimaEngine (`DevDeck/Engine/ColimaEngine.swift`)

- `isRunning()`: ищет `ha.pid` по маске `~/.colima/_lima/*/ha.pid` (профиль `default` соответствует
  lima-инстансу `colima`, остальные — `colima-<профиль>`), читает pid, проверяет `kill(pid, 0)`.
  `rc == 0` — жив; `errno == EPERM` — жив, но чужой (тоже считается запущенным); `ESRCH` — мёртв.
  Любой живой pid среди профилей → движок запущен.
- `isInstalled()`: существует `/opt/homebrew/bin/colima` или `/usr/local/bin/colima`, либо каталог
  `~/.colima`. Через `env` не ходим — это подпроцесс.
- `displayName` — `"colima"`.

### DockerDesktopEngine (`DevDeck/Engine/DockerDesktopEngine.swift`)

- `isRunning()`: `NSRunningApplication.runningApplications(withBundleIdentifier: "com.docker.docker")`
  непусто **и** `connect()` к `~/.docker/run/docker.sock` успешен. Сокет живёт и когда Resource Saver
  усыпил VM — это по-прежнему «запущен», будить движок ради уточнения мы не станем.
- `isInstalled()`: `NSWorkspace.shared.urlForApplication(bundleIdentifier: "com.docker.docker") != nil`.
- `displayName` — `"Docker Desktop"`.
- `com.docker.vmnetd` и `com.docker.socket` как признак жизни **не использовать**: это launchd-демоны,
  они живут и при остановленном приложении.

### Probe-паттерн

Обе реализации ходят наружу через инжектируемые протоколы, чтобы тесты не трогали реальных путей
и реального списка процессов:

```swift
protocol ProcessLivenessChecking: Sendable { func isAlive(pid: Int32) -> Bool }
protocol PathProbing: Sendable { func exists(_ path: String) -> Bool
                                 func contents(ofFile path: String) -> String?
                                 func paths(matching glob: String) -> [String] }
protocol AppPresenceProbing: Sendable { func isRunning(bundleID: String) -> Bool
                                        func isInstalled(bundleID: String) -> Bool }
protocol UnixSocketProbing: Sendable { func canConnect(to path: String) -> Bool }
```

Живые реализации — тонкие обёртки над `kill`, `FileManager`, `NSRunningApplication`/`NSWorkspace`
и `connect(2)` на `AF_UNIX` в неблокирующем режиме. В `init` у движков — значения по умолчанию,
как у существующих зондов.

## Изменение 2 — выбор активного движка

Файл `DevDeck/Engine/EngineModel.swift`, `@Observable`, `@MainActor`:

```swift
@Observable @MainActor
final class EngineModel {
    private(set) var active: (any ContainerEngine)?
    private(set) var isActiveRunning: Bool = false
    func refresh()   // дёргается таймером трея
}
```

Новое поле конфига `settings.containerEngine: EnginePreference` (`auto` / `colima` / `dockerDesktop`).
Сам `enum EnginePreference: String, Codable` живёт в `DevDeck/Models/Config.swift` рядом с прочими
настройками и декодится с дефолтом `.auto` — как все остальные поля, без bump'а схемы.
Переключатель в `SettingsView` — рядом с тумблерами мониторинга.

Правила `auto`, по порядку:

1. Запущенный движок — он и активен.
2. Запущены оба — colima (на машине разработчика она основная; неоднозначность разрешается вручную
   настройкой).
3. Не запущен ни один — установленный (colima приоритетнее при обоих установленных).
4. Ни один не установлен — активного движка нет: точки в трее нет, VM-метрики скрыты.

Явное значение (`colima` / `dockerDesktop`) отключает автоопределение целиком, даже если выбранный
движок не установлен — тогда состояние «не запущен».

Пересчёт: из существующего 2-секундного таймера `MenuBarController` (там уже считается уровень
давления памяти) и при перечитывании конфига `FileWatcher`'ом.

Владение: создаётся в `AppDelegate`, передаётся в `MenuBarController` и кладётся в окружение
попапа рядом с остальными моделями.

## Изменение 3 — точка в трее

В `MenuBarController` появляется второй `NSView` по образцу существующего `badgeView`, привязанный
констрейнтами к левому нижнему углу глифа:

```swift
engineBadgeView.leadingAnchor.constraint(equalTo: button.centerXAnchor, constant: -half)
engineBadgeView.bottomAnchor.constraint(equalTo: button.centerYAnchor, constant: half)
```

Цвет — чистой функцией в `TrayIcon`, чтобы её можно было протестировать:

```swift
static func engineBadgeColor(running: Bool) -> NSColor?   // .systemGreen / nil
```

`nil` → точка скрыта. Обновляется тем же тиком таймера, что и бейдж давления.
`accessibilityDescription` кнопки — «DevDeck — colima запущена» / «DevDeck — colima остановлена»
(имя берётся из движка; без движка остаётся «DevDeck»).

Отдельной настройки «показывать точку» нет — YAGNI, и бейдж давления такой настройки тоже не имеет.

## Изменение 4 — нейминг

Подписи берут имя живого движка (решение принято при обсуждении).

- `HeaderMetric.vmColima` → `.vmEngine`. Статический `var title` для этого case превращается в
  `func title(engineName: String?) -> String`: `"VM colima"`, `"VM Docker Desktop"`, а при `nil` —
  `"VM"`. Остальные case отдают прежние строки. Вызовы в `PopoverView` и `SettingsView` получают
  имя из `EngineModel`.
- `L10n.restartColima`, `restartColimaConfirmTitle` и текст подтверждения — параметризуются именем:
  `restartEngine(_ name: String)` и далее.
- `DockerHost.colima` → `.engineVM` (смысл у него всегда был «docker уровня VM», а не «именно
  colima»). Case остаётся **первым** в `allCases`: `CleanupCommands.id(_:on:)` выводит UUID из
  индекса, и порядок менять нельзя, иначе синтетические команды очистки потеряют своё состояние.
  `rawValue` нигде не сохраняется — проверено, `DockerHost` живёт только в памяти.
- `DockerHost.wrap(_:)` переезжает в `ContainerEngine` как требование протокола
  `func wrap(_ script: String) -> String`; у colima это прежнее `colima ssh -- sh -c <quoted>`,
  у Docker Desktop — скрипт возвращается без изменений (docker CLI работает прямо с хоста).
  Для `.minikube` обёртка остаётся там же, где была, — это не движок, а вложенный демон.
- Тексты подсказок в `L10n`, говорящие про активный движок, получают имя подстановкой. Фактура про
  page cache lima («гипервизор держит все страницы…») остаётся как есть: она верна для colima и
  будет уточнена во втором куске, когда появятся зонды Docker Desktop.
- `CleanupCommands.restartColima` → `restartEngine(_ engine:)`. Для colima результат прежний
  (`colima restart && minikube start`), для Docker Desktop в этом куске команда не строится —
  кнопка не показывается.

## Изменение 5 — поведение на машине с Docker Desktop

Зонды остаются colima-специфичными (их замена — второй кусок), поэтому их результаты гейтятся по
типу активного движка: `ProcessManager` получает замыкание `engineKind: () -> ContainerEngineKind?`
тем же приёмом, что и существующее `isClusterHealthEnabled`. При `kind != .colima` зонды памяти VM,
диска VM и здоровья кластера не запускаются, кеши держатся в `nil`, а ячейки **скрываются**, а не
показывают пустоту.

Итог для машины с Docker Desktop после первого куска: точка в трее работает, подписи говорят
«Docker Desktop», VM-метрик нет, страница «Очистка» показывает только блок minikube, если тот есть.

## Тесты

Новый `DevDeckTests/EngineDetectionTests.swift` с фейками всех четырёх протоколов:

- colima: pid-файл есть и процесс жив → запущена; pid жив, но `EPERM` → запущена; `ESRCH` → нет;
  файла нет → нет; мусор вместо pid → нет.
- Docker Desktop: приложение запущено + сокет отвечает → запущен; приложение запущено, сокет
  молчит → нет; приложение не запущено → нет (сокет не проверяем).
- `auto`: запущена одна colima; запущен один Docker Desktop; запущены оба → colima; не запущен
  никто, установлены оба → colima; не установлен никто → активного нет.
- явное значение настройки перебивает автоопределение, в том числе когда движок не установлен.

Остальное:

- `TrayIcon.engineBadgeColor(running:)` — обе ветки.
- `HeaderMetricTests` — обновить под `title(engineName:)`, включая `nil` → «VM».
- `CleanupCommandsTests` — новый тест: UUID'ы команд очистки после переименования case совпадают
  с зафиксированными строками (защита от перестановки `allCases`).

Процессов и сети тесты не трогают — probe-паттерн проекта соблюдён.

## Что сюда не входит

Второй кусок — зонды Docker Desktop: диск (`Docker.raw` + `/system/df` по unix-сокету), лимиты
(`docker info`), очистка (`docker … prune` прямо с хоста, ssh не нужен), перезапуск
(`docker desktop restart`), и отдельное решение для памяти внутри VM — по требованию, а не по
таймеру, чтобы не будить Resource Saver.

Третий кусок — OrbStack (`orb status` отдаёт состояние кодом выхода, `orb config show` — лимиты),
если дойдёт до смены движка.

## Уточнения при планировании (2026-09-18)

При разборе кода для плана выяснилось несколько вещей, которые меняют детали, но не дизайн.
Каждая оговорена здесь, чтобы спека и план не расходились.

1. **`wrap` остаётся вне протокола до второго куска.** Скрипт для «docker уровня VM» строится в
   двух местах: `DockerHost.wrap` (строка для раннера) и `LiveDockerUsageProbe.invocation` (argv для
   `ProcessTree.run`). В первом куске у `engineVM` есть только colima-путь, а под другим движком
   этот блок скрыт — перенос в движок был бы чистой перекладкой без поведения. Оба места
   переносятся в `ContainerEngine` вместе с зондами Docker Desktop.
2. **Гейт colima-зондов — композицией существующих замыканий**, а не новым `engineKind` в
   `ProcessManager`: `AppDelegate` собирает `isVMMonitoringEnabled` и `isClusterHealthEnabled` как
   «настройка включена И активный движок — colima». Замыкания уже чистят кеши при выключении,
   `ProcessManager` не меняется.
3. **`PathProbing`** отдаёт `directoryEntries(at:)` вместо glob: для `~/.colima/_lima/*/ha.pid`
   хватает листинга одного каталога.
4. **`DockerHost.rawValue` виден пользователю** — в названиях команд очистки («Очистка: … (colima)»)
   и в заголовке подтверждения. После переименования case там стало бы «engineVM», поэтому имя
   хоста в UI берётся из нового `L10n.dockerHostLabel(_:engineName:)`.
5. **Подсказки метрик (`metricHelp`) в этом куске не меняются.** Там, где они упоминают colima,
   это фактура про lima (page cache, `colima list`), а ячейки, к которым они относятся, под другим
   движком скрыты. Имя движка подставляется в подписи ячеек, тумблеры настроек, тексты страницы
   очистки и кнопку перезапуска.
6. **Строка VM в списке энергопотребителей** была зашита как «VM colima» в
   `EnergyTally.displayName`. Теперь это нейтральное `EnergyTally.vmName`, а попап рисует его как
   «VM <движок>».
7. **Страница очистки** получает `visibleHosts`: блок `engineVM` и его зонд `docker system df`
   пропускаются под любым движком, кроме colima, — иначе `colima ssh` запускался бы на машине без
   colima.
8. **Неизвестное значение `containerEngine`** в `config.json` (опечатка, будущий движок) читается как
   `auto`, а не роняет разбор всего конфига.
