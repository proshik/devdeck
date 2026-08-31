# DevDeck — восстановление вкладок Claude Code в Ghostty после перезагрузки

> Статус: **план, к реализации**. Реализацию делать в этом репозитории. Без явной просьбы **не коммитить** (см. `CLAUDE.md`).

## Контекст (зачем это)

У пользователя постоянно открыто около десятка вкладок Ghostty, в каждой — сессия Claude Code
в своём проекте; самые долгоживущие висят неделями. Перезагрузка ноутбука убивает всё разом:
процессы не переживают ребут в принципе, а `window-save-state` у Ghostty восстанавливает окно
с шеллом, но не запущенный в нём процесс. Руками поднимать девять вкладок, вспоминая, какая
сессия в каком каталоге, — это и есть та рутина, ради устранения которой DevDeck написан.

Поэтому «не потерять вкладки» технически означает: **запомнить пары (рабочий каталог, id сессии)
для каждой claude-вкладки и после ребута пересоздать вкладки с `claude --resume <id>`**.

DevDeck подходит для этого лучше отдельного скрипта, и не по вкусовым причинам:

- он и так постоянно живёт в меню-баре и умеет автозапуск при входе (`SMAppService`,
  `SettingsView.swift:33`) — значит, есть кому поймать момент старта Ghostty через
  `NSWorkspace.didLaunchApplicationNotification`; из шелла надёжного способа поймать это нет;
- в нём **уже есть работающая интеграция с Ghostty**: `AppleScriptTabLauncher`
  (`Process/TerminalCommandRunner.swift:100`) создаёт вкладки через `new surface configuration` +
  `new tab with configuration`. Мы переиспользуем механизм, а не изобретаем его;
- конфиг, диагностический лог, страницы главного окна, локализация и probe-паттерн для тестов —
  всё на месте.

## Проверенные факты (разведка выполнена, не гипотезы)

1. **Ghostty 1.3.1 имеет полноценный AppleScript-словарь** (`Ghostty.app/Contents/Resources/Ghostty.sdef`),
   в конфиге пользователя `macos-applescript = true`. Чтение: `windows` → `tabs` → `terminals`
   со свойствами `name`, `index`, `working directory`. Запись: `new surface configuration`
   (свойства `initial working directory`, `command`, `initial input`, `environment variables`,
   `wait after command`), `new tab ... with configuration`, `input text to <terminal>`.
2. **Перечисление работает прямо сейчас** и отдаёт ровно то, что нужно:
   `TAB 4 | ✳ fix-own-memory-group-chat | /Users/proshik/work/group/axarta/project/grount`.
3. **Заголовок вкладки однозначно ведёт к id сессии.** В транскрипте
   `~/.claude/projects/<slug>/<uuid>.jsonl` есть строка
   `{"type":"ai-title","aiTitle":"fix-own-memory-group-chat","sessionId":"4239e258-…"}`.
   Проверено на трёх заголовках — каждый нашёлся ровно в одном файле.
4. **Из процесса id сессии не достать.** `lsof` отдаёт `cwd`, но транскрипт claude открытым
   не держит; к тому же у пользователя три процесса сидят в одном `grount` — cwd как ключ не годится.
   Отсюда решение резолвить через заголовок.
5. **`ghostty +new-window` на macOS не поддерживается** («not supported on this platform») —
   единственный рабочий путь именно AppleScript.
6. В `Info.plist` **нет** `NSAppleEventsUsageDescription` — для запроса Automation его надо добавить.

## Зафиксированные решения

1. **Никаких хуков в `~/.claude/settings.json`.** Источник правды — AppleScript-перечисление вкладок
   Ghostty плюс чтение `~/.claude/projects/`. Конфиг Claude Code не трогаем вообще.
2. **Восстанавливаются все живые claude-вкладки**, без ручной пометки и без «закрепления».
3. **Триггер — старт Ghostty**, ровно один раз на загрузку системы.
4. **Команда в восстановленной вкладке выполняется сразу** (`claude --resume <id>` через
   `initial input`), поверх обычного login-шелла: после выхода из claude остаётся живой zsh,
   вкладка не закрывается.
5. **Одно окно, порядок вкладок из снимка.** Несколько окон, геометрия и splits — вне MVP.
6. **Тумблер в двух местах:** секция в поповере (трей) и Settings — одна и та же настройка.
7. **Настройка живёт в `config.json`** (`Settings.claudeTabsRestore`), а не в UserDefaults:
   это флаг поведения, как `vmMemoryMonitoring`, и он должен правиться руками. По умолчанию `false`.

## Архитектура

- Новый `@MainActor @Observable` синглтон **`ClaudeTabsModel`**, собирается в `AppDelegate`
  и прокидывается через `.environment(...)` — ровно как `ProxyManager` и `CleanupModel`
  (`AppDelegate.swift:12–13`).
- Все внешние зависимости — за протоколами (**probe-паттерн**): чтение вкладок, выполнение
  AppleScript, чтение транскриптов, время загрузки системы, часы. Тесты не запускают osascript,
  не трогают Ghostty и не читают реальный `~/.claude`.
- Логика решений — **чистые функции** (`SessionResolver`, `RestorePlanner`), они и покрываются
  тестами полностью; императивная часть остаётся тонкой.
- Новые `.swift` подхватываются автоматически (`PBXFileSystemSynchronizedRootGroup`) —
  **`.pbxproj` руками не править**. `Info.plist` подключён через build setting, поэтому
  добавление `INFOPLIST_KEY_NSAppleEventsUsageDescription` тоже не требует правки проекта.

## Изменения модели данных

**`Models/Config.swift`**, в `struct Settings` (строка 5) добавить:

```swift
var claudeTabsRestore: Bool          // default false
```

Декодируется со значением по умолчанию, как все остальные поля → `schemaVersion` не бумпаем.

**Новый `Models/ClaudeTabsSnapshot.swift`** — снимок хранится **отдельным файлом**, не в `config.json`:
он машинный, переписывается раз в минуту и пользователю руками не нужен.

```swift
struct ClaudeTabEntry: Codable, Equatable {
    var order: Int                   // позиция вкладки в окне на момент снимка
    var title: String                // заголовок как есть, для UI
    var workingDirectory: String
    var sessionID: String?           // nil → не разрезолвилось, восстановим только каталог
}

struct ClaudeTabsSnapshot: Codable, Equatable {
    var bootTime: Date               // kern.boottime на момент снимка
    var capturedAt: Date
    var tabs: [ClaudeTabEntry]
}
```

Файл: `~/Library/Application Support/DevDeck/claude-tabs.json` (рядом с `config.json`).
Отметка «в эту загрузку уже восстанавливали» — в UserDefaults, ключ `claudeTabs.restoredBootTime`:
это состояние выполнения, ему не место ни в конфиге, ни в снимке, который перезаписывается.

## Новые подсистемы — `DevDeck/ClaudeTabs/`

| Файл | Ответственность |
|---|---|
| `GhosttyTabReader.swift` | `protocol GhosttyTabReading` + `LiveGhosttyTabReader` (osascript) + парсер вывода в `[GhosttyTab]` |
| `TranscriptIndex.swift` | `protocol TranscriptIndexing`: по cwd отдать `[(aiTitle, sessionID, mtime)]`; кэш по (путь, mtime) |
| `SessionResolver.swift` | **Чистая**: `[GhosttyTab]` + индекс → `[ClaudeTabEntry]` |
| `ClaudeTabsStore.swift` | Чтение/запись `claude-tabs.json` |
| `BootTime.swift` | `protocol BootTimeProviding` + живая реализация через `sysctl kern.boottime` |
| `RestorePlanner.swift` | **Чистая**: снимок + boot time + флаги → `RestoreDecision` |
| `TabRestorer.swift` | Исполняет план через AppleScript, с паузами |
| `ClaudeTabsModel.swift` | `@Observable`: таймер снимков, наблюдатели `NSWorkspace`, состояние для UI |

### `GhosttyTab`

```swift
struct GhosttyTab: Equatable {
    var windowID: String
    var index: Int
    var title: String
    var workingDirectory: String
}
```

Читается одним `osascript`, который печатает строки вида
`<windowID>\t<index>\t<title>\t<cwd>`; парсер — чистая функция по разделителю табуляции
Заголовок пользовательский и может содержать что угодно, поэтому парсер берёт первые два поля
от начала строки (`windowID`, `index`), последнее — от конца (`cwd`), а всё, что осталось между
ними, считает заголовком.
Перед вызовом — проверка `pgrep -x ghostty`, как в существующем `AppleScriptTabLauncher`.

### Алгоритм резолва (`SessionResolver`)

1. **Нормализация заголовка**: срезать ведущие символы статуса и пробелы (`✳`, `◐` и прочие
   не-буквенно-цифровые в начале строки), обрезать хвостовые пробелы.
2. **cwd → каталог проекта**: слаг = путь, в котором `/` заменён на `-` (`/Users/proshik/work/…/base13`
   → `-Users-proshik-work-…-base13`). Если каталога по слагу нет — фолбэк: перебрать
   `~/.claude/projects/*` и сверить поле `cwd` из первой строки транскрипта.
3. **В каталоге**: файлы `*.jsonl` по убыванию mtime; каждый сканируется построчно на подстроку
   `"type":"ai-title"`, берётся **последняя** такая строка (заголовок сессии обновляется по ходу) →
   `aiTitle` + `sessionId`. Результат кэшируется по (путь, mtime), так что дорогой только первый проход.
4. **Сопоставление**: сначала точное равенство нормализованных заголовков, затем совпадение по
   префиксу (на случай обрезанного заголовка). Уже использованные `sessionID` исключаются из
   кандидатов — так разводятся вкладки с одинаковыми заголовками.
5. Не сопоставилось → `sessionID = nil`; вкладка остаётся в снимке.

### Снятие снимка

Таймер в `ClaudeTabsModel`, **раз в 60 секунд**, работает только когда `claudeTabsRestore == true`
и Ghostty запущен. Дополнительно — на `NSWorkspace.willPowerOffNotification` и в
`applicationWillTerminate`.

**Правило записи: снимок пишется, только если распознана хотя бы одна вкладка.** Иначе штатный
выход из Ghostty обнулил бы снимок ровно перед выключением — то есть ломал бы фичу именно в тот
момент, ради которого она существует.

### Триггер и план восстановления

Наблюдатель `NSWorkspace.shared.notificationCenter` на `didLaunchApplicationNotification`,
фильтр по `bundleIdentifier == "com.mitchellh.ghostty"`.

`RestorePlanner.decide(...)` — чистая функция, отдаёт `.skip(reason)` или `.restore([RestoreAction])`.
Пропуск, если: фича выключена; снимка нет; снимок пуст; `snapshot.bootTime == currentBootTime`
(Ghostty просто перезапустили в той же загрузке — это не ребут); `restoredBootTime == currentBootTime`
(в эту загрузку уже восстанавливали).

```swift
enum RestoreAction: Equatable {
    case inputText(cwd: String, sessionID: String?)   // в уже открытый терминал
    case newTab(cwd: String, sessionID: String?)      // новой вкладкой
}
```

- **Первая запись** уходит через `input text` в терминал, который Ghostty создал при запуске:
  строкой `cd '<cwd>' && claude --resume <id>`. Так не остаётся болтающейся пустой вкладки.
  **Условие:** так делаем, только если у запущенного Ghostty ровно одно окно с одной вкладкой.
  Если macOS восстановил окна сам (`window-save-state`) и вкладок уже несколько — ничего никуда
  не печатаем, все записи открываются новыми вкладками: печатать в чужую вкладку хуже, чем
  оставить одну лишнюю пустую.
- Вкладки создаются **в переднем окне** Ghostty (`new tab` без параметра `in`).
- **Остальные** — `new tab with configuration` с `initial working directory = cwd` и
  `initial input = "claude --resume <id>\n"`.
- Записи с `sessionID == nil` открывают просто шелл в нужном каталоге.
- Пауза **1.5 с** после нотификации (Ghostty должен создать первое окно), шаг **700 мс** между
  вкладками, чтобы девять процессов claude не стартовали в одну секунду.
- Путь и id подставляются через существующий `ShellQuoting` / экранирование
  `AppleScriptTabLauncher.escape`; руками кавычки не клеим.

После успешного выполнения — записать `restoredBootTime = currentBootTime`.

## UI

**Поповер (трей) — `MenuBar/ClaudeTabsSectionView.swift`**, рядом с `ProxySectionView`
(`PopoverView.swift:79`), сворачиваемая секция с `@AppStorage("popover.section.claudeTabs.collapsed")`:

- `Toggle` на `store.config.settings.claudeTabsRestore` — тот самый тумблер в трее;
- строка состояния: «в снимке: N вкладок · ЧЧ:ММ»;
- кнопки «Снять снимок» и «Восстановить сейчас» (вторая активна, когда снимок непустой).

**Settings** — тот же тумблер, привязанный к тому же полю конфига (не копия состояния).

**Главное окно** — страница `Claude tabs` со списком записей снимка: порядок, заголовок, каталог
и признак «сессия найдена / только каталог». Плюс те же две кнопки.

**Локализация** — новые строки в `L10n` парами EN/RU, как всё остальное.

## Обработка ошибок и краёв

- **Automation не разрешён** (osascript `-1743`): диагностический лог плюс строка ошибки прямо
  в секции трея и на странице — там, где пользователь и нажал кнопку. Системное уведомление для
  этого не нужно: ошибка относится к действию, которое он только что совершил, и должна лежать
  рядом с ним. Тумблер **не** сбрасываем — пользователь разрешит доступ и продолжит.
- **Спурьезная ошибка `-1708`** при `new tab` — известна существующему коду; AppleScript
  оборачиваем в `try … end try`, как в `AppleScriptTabLauncher.osascriptArgs`.
- **Ghostty не запущен** в момент снимка → снимок пропускается молча.
- **macOS сам восстановил окна Ghostty** (`window-save-state`): вкладок при старте больше одной →
  переходим на путь «всё новыми вкладками» (см. выше). Дубли при этом возможны — они видны
  глазом и закрываются руками; молча печатать в существующие вкладки мы не будем.
- **Битый `claude-tabs.json`** → считаем, что снимка нет; файл перезаписывается следующим снимком.
- **Больше 20 записей** в снимке → восстанавливаем первые 20, остальное в лог: защита от лавины
  процессов, если что-то пойдёт не так с резолвом.
- **`claude` не в PATH** у неинтерактивного шелла — не наша забота: команда уходит в живой
  интерактивный zsh вкладки, где PATH уже собран.

## Риски (названы честно)

- **Формат `ai-title` — внутренний формат Claude Code**, его могут поменять или убрать.
  Ломается мягко: сессия не резолвится → вкладка открывается шеллом в правильном каталоге.
  Это худший сценарий деградации, и он всё равно лучше нынешнего «потеряли всё».
- **Свежая сессия без `ai-title`** (заголовок ещё не сгенерирован) не разрезолвится по той же схеме.
- **Одинаковые заголовки в одном каталоге** разводятся по mtime — порядок может разъехаться.
- **Снимок устареет**, если Ghostty закрыт задолго до выключения: восстановятся вкладки,
  которые пользователь уже закрыл руками.
- **Automation-разрешение** запрашивается системой один раз; до выдачи фича не работает.

## MVP vs отложенное (YAGNI)

**В MVP:** одно окно, порядок вкладок, резолв сессий, тумблер в трее и Settings, страница
со списком, ручные «снять снимок» / «восстановить сейчас».

**Отложено:** восстановление нескольких окон и их геометрии; splits; вкладки, не относящиеся
к Claude Code; ручное закрепление/исключение отдельных сессий; выбор «выполнять сразу или
только подставить команду».

## Пофайлово

**Новое:**
- `DevDeck/Models/ClaudeTabsSnapshot.swift`
- `DevDeck/ClaudeTabs/GhosttyTabReader.swift`
- `DevDeck/ClaudeTabs/TranscriptIndex.swift`
- `DevDeck/ClaudeTabs/SessionResolver.swift`
- `DevDeck/ClaudeTabs/ClaudeTabsStore.swift`
- `DevDeck/ClaudeTabs/BootTime.swift`
- `DevDeck/ClaudeTabs/RestorePlanner.swift`
- `DevDeck/ClaudeTabs/TabRestorer.swift`
- `DevDeck/ClaudeTabs/ClaudeTabsModel.swift`
- `DevDeck/MenuBar/ClaudeTabsSectionView.swift`
- `DevDeck/MainWindow/ClaudeTabsView.swift`
- Тесты: `DevDeckTests/SessionResolverTests.swift`, `RestorePlannerTests.swift`,
  `GhosttyTabParserTests.swift`, `ClaudeTabsStoreTests.swift`

**Правится:**
- `DevDeck/Models/Config.swift` — поле `claudeTabsRestore`
- `DevDeck/AppDelegate.swift` — создание `ClaudeTabsModel`, подписки `NSWorkspace`, прокидывание в environment
- `DevDeck/MenuBar/PopoverView.swift` — вставка секции рядом с `ProxySectionView`
- `DevDeck/MainWindow/SettingsView.swift` — тумблер
- `DevDeck/MainWindow/MainWindowView.swift` — пункт `Claude tabs` в навигации
- `DevDeck/Localization/L10n.swift` — строки EN/RU
- `Info.plist` (через build setting) — `INFOPLIST_KEY_NSAppleEventsUsageDescription`

## Проверка

```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj \
  -scheme DevDeck -destination 'platform=macOS'
```

Тестами покрываются:

- `SessionResolver` — глиф статуса срезается; точное совпадение; совпадение по префиксу;
  два одинаковых заголовка → разные сессии; нет совпадения → `sessionID == nil`.
- `RestorePlanner` — восстанавливаем после ребута; пропускаем при перезапуске Ghostty в той же
  загрузке; пропускаем повторно в одну загрузку; пропускаем при выключенной настройке и на пустом
  снимке; первая запись даёт `.inputText`, остальные `.newTab`; ограничение в 20 записей.
- Парсер вывода `osascript` — заголовки с табами и пробелами, пустой вывод, одно окно, несколько окон.
- `RestorePlanner` — при нескольких уже открытых вкладках первая запись тоже становится `.newTab`.
- `ClaudeTabsStore` — round-trip, битый файл.

**Ручная проверка без перезагрузки:** снять снимок при открытых вкладках, затем подставить в
`claude-tabs.json` заведомо старый `bootTime`, закрыть Ghostty и запустить заново — должно
восстановиться и записаться `restoredBootTime`.
