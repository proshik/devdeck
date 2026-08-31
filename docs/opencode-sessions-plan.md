# DevDeck — восстановление вкладок opencode рядом с Claude Code

> Статус: **план, к реализации**. Без явной просьбы **не коммитить** (см. `CLAUDE.md`).
> Базовая фича: `docs/claude-tabs-restore-plan.md` — читать первой.

## Зачем

Механизм восстановления вкладок написан под Claude Code и знает про него всё: где лежат
транскрипты, как из них достать `ai-title`, какой командой возобновить сессию. Пользователь
работает и в opencode, и терять его сессии при перезагрузке так же обидно. Задача — вынести
агентно-зависимое за протокол и добавить второго поставщика.

## Проверенные факты (разведка выполнена на живой системе)

opencode 1.18.20, `/opt/homebrew/bin/opencode`.

1. **Заголовок вкладки он ставит**, в виде `OC | <название сессии>`:
   `OC | Проект: обзор и описание` при cwd `/Users/proshik/work/group/me/project/base13`.
2. **Есть машинный листинг** — `opencode session list --format json`, привязанный к каталогу
   проекта (из чужого каталога возвращает пусто). Пример записи:
   `{"id":"ses_fa8f30e90ffejKVUho9L7fnDjx","title":"Проект: обзор и описание","updated":1788166882579,
   "created":1788166861167,"projectId":"…","directory":"/Users/proshik/work/group/me/project/base13"}`
3. **Снятие префикса `OC | ` даёт точное совпадение** с полем `title` из листинга.
4. **Возобновление по id есть**: `opencode --session <id>` (плюс `-c` — продолжить последнюю,
   `--fork` — ответвиться). Прямой аналог `claude --resume <id>`.
5. `updated`/`created` — миллисекунды эпохи, то есть признак «свежее первым» для разведения
   одинаковых заголовков у нас есть, как и mtime у транскриптов Claude.
6. Сессии лежат в SQLite `~/.local/share/opencode/opencode.db` (таблица `session` с полями
   `id`, `title`, `directory`). **В базу не лезем**: она внутренний формат, CLI — публичный.

## Зафиксированные решения

1. **Протокол на поставщика**, а не ветвление по `if agent == …`. Агентно-зависимого ровно три
   вещи: как получить сессии каталога, как из заголовка вкладки узнать свою сессию, какой командой
   её открыть.
2. **Нормализация заголовка живёт внутри поставщика.** Claude срезает глиф статуса (`✳`, `◐`),
   opencode — префикс `OC | `. Знание о чужом косметическом формате не размазывается по общему коду.
3. **Префикс `OC | ` — дешёвый фильтр, не источник истины.** Спрашивать оба поставщика про каждый
   каталог значит запускать процесс `opencode` на каждый каталог при каждом снимке. Поэтому
   opencode спрашиваем только про вкладки, чей заголовок на него похож. Если формат префикса
   изменится, фича деградирует до «сессия не опознана → шелл в каталоге», а не сломается.
4. **Запись снимка получает `provider`** со значением по умолчанию `"claude"`: снимки, снятые до
   этой правки, читаются как есть, `schemaVersion` не бумпается.
5. **opencode может быть не установлен.** Тогда листинг возвращает пусто молча — как и всё
   остальное в этой фиче, отсутствие внешнего инструмента не ошибка.

---

### Task 1: Протокол поставщика и Claude за ним

Чистый рефакторинг: поведение не меняется, все существующие тесты обязаны остаться зелёными —
это и есть страховочная сетка задачи.

**Файлы:** создать `DevDeck/ClaudeTabs/AgentSessionProvider.swift`; правки в
`TranscriptIndex.swift`, `SessionResolver.swift`, `ClaudeTabsModel.swift`,
`Models/ClaudeTabsSnapshot.swift`; тесты — существующие адаптировать, добавить на `provider`.

- [ ] **Шаг 1: Протокол и общий тип сессии**

```swift
/// One resumable agent session, as its own tool reports it.
struct AgentSession: Equatable, Sendable {
    var id: String
    var title: String
    /// Newest first is what breaks ties between two tabs with the same title, so every provider
    /// must supply something orderable — a transcript's mtime, a listing's `updated`.
    var lastActivity: Date
}

/// One coding agent, from the restore mechanism's point of view.
///
/// Only three things differ between agents; everything else — reading tabs, the snapshot, the
/// boot-time check, the planner, the restorer — is shared.
protocol AgentSessionProvider: Sendable {
    /// Stable key stored in the snapshot, e.g. "claude" / "opencode".
    var id: String { get }

    /// Cheap pre-filter: does this tab title look like it belongs to this agent at all?
    /// Answering false must be free — it exists so we do not spawn a process per directory
    /// for a tab that plainly is not ours.
    func mayOwn(tabTitle: String) -> Bool

    func sessions(inDirectory directory: String) -> [AgentSession]

    /// The agent's own title normalization: Claude prefixes a status glyph, opencode "OC | ".
    func normalize(tabTitle: String) -> String

    /// The shell line that reopens the session.
    func command(resuming sessionID: String, in cwd: String) -> String
}
```

- [ ] **Шаг 2: `ClaudeSessionProvider`**

Существующий `LiveTranscriptIndex` остаётся как есть (он уже умеет `titles(forWorkingDirectory:)`
с кэшом) и становится деталью реализации нового `ClaudeSessionProvider`, который:
- `id` → `"claude"`;
- `mayOwn` → `true` **всегда**. Claude — поставщик по умолчанию и стоит последним в списке:
  у него нет опознавательного префикса, только глиф статуса, который меняется по ходу работы;
- `sessions` → `titles(forWorkingDirectory:)`, отображённые в `AgentSession`;
- `normalize` → нынешний `SessionResolver.normalize` (срезание ведущих не-буквенно-цифровых);
- `command` → нынешняя логика `RestoreCommand.text`, включая `claude attach` для фоновых сессий.

- [ ] **Шаг 3: Резолвер по списку поставщиков**

`SessionResolver.resolve` принимает `providers: [AgentSessionProvider]` и для каждой вкладки идёт
по ним по порядку, беря первого, у кого `mayOwn` и нашлось совпадение. Множество `claimed`
остаётся, но становится ключом по паре `(providerID, sessionID)`. `ClaudeTabEntry` получает
`var provider: String` с декодированием по умолчанию `"claude"`.

- [ ] **Шаг 4: Тесты и прогон**

Все существующие тесты зелёные без правок смысла (допустимы правки вызовов под новую сигнатуру).
Плюс: снимок старого формата (без `provider`) декодируется как `"claude"`.

---

### Task 2: Поставщик opencode

**Файлы:** создать `DevDeck/ClaudeTabs/OpencodeSessionProvider.swift`; правки в
`TabRestorer.swift` (команда берётся у поставщика), `ClaudeTabsModel.swift` (список поставщиков),
`ClaudeTabsView.swift` (колонка «агент»); тесты — новый класс.

- [ ] **Шаг 1: Разбор листинга — чистая функция**

```swift
enum OpencodeSessions {
    /// Parsing of `opencode session list --format json`, lenient by the same rule as everything
    /// else here: another tool's output format must cost us a missed session, never a crash.
    static func parse(_ data: Data) -> [AgentSession] {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let id = entry["id"] as? String, !id.isEmpty,
                  let title = entry["title"] as? String else { return nil }
            let millis = (entry["updated"] as? Double) ?? (entry["created"] as? Double) ?? 0
            return AgentSession(id: id, title: title,
                                lastActivity: Date(timeIntervalSince1970: millis / 1000))
        }
        .sorted { $0.lastActivity > $1.lastActivity }
    }
}
```

- [ ] **Шаг 2: Поставщик**

- `id` → `"opencode"`;
- `mayOwn(tabTitle:)` → заголовок начинается с `"OC | "` (константа `titlePrefix`);
- `normalize` → снять префикс и обрезать пробелы;
- `sessions(inDirectory:)` → запустить `/bin/zsh -lc "opencode session list --format json"` с
  `currentDirectoryURL` = каталог (листинг привязан к проекту), **вычитать пайпы до `waitUntilExit`**
  — то же правило, что и везде в этой фиче; ненулевой код возврата или отсутствие бинаря → пусто;
- `command` → `cd <quoted cwd> && opencode --session <quoted id>`.

Порядок поставщиков в модели: `[OpencodeSessionProvider(), ClaudeSessionProvider()]` — сначала тот,
у кого есть точный префикс, Claude последним как поставщик по умолчанию.

- [ ] **Шаг 3: Восстановление отдаёт команду поставщику**

`RestoreAction` несёт `provider`, `TabRestorer` спрашивает команду у соответствующего поставщика
вместо зашитого `RestoreCommand.text`. Запись без распознанного поставщика по-прежнему открывает
шелл в каталоге.

- [ ] **Шаг 4: Страница показывает агента**

В таблице `ClaudeTabsView` — колонка с именем агента, чтобы было видно, чем вкладка вернётся.

- [ ] **Шаг 5: Тесты**

Разбор листинга (нормальный, мусор, пустой, без `updated`), `mayOwn` на обоих видах заголовков,
`normalize` на префиксе, команда возобновления, и резолвер на смешанном наборе вкладок —
opencode-вкладка получает opencode-сессию, claude-вкладка claude-сессию.

---

## Дальше (обсуждено, не сделано)

Две отдельные работы, обе подтверждены пользователем как нужные.

**1. История вкладок в разделе «Вкладки агентов».** Сейчас раздел показывает только текущий
снимок — зеркало того, что открыто. Нужно хранить не последний снимок, а цепочку, и показывать
рядом с текущими вкладками историю, чтобы можно было найти и вернуть вкладку, закрытую вчера.
Заготовки для этого уже есть: `TranscriptIndex` и `OpencodeSessionProvider` умеют перечислять
сессии каталога с временем последней активности, а `TabRestorer` — открыть вкладку любой командой.

**2. Поддержка других терминалов.** Весь механизм зашит на Ghostty: чтение вкладок и создание
новых идёт через его AppleScript-словарь. Это вторая ось абстракции, независимая от агентов.
Разведанное: у iTerm2 развитый AppleScript, у Terminal.app свой, у WezTerm вместо скриптинга есть
CLI (`wezterm cli list`) — он надёжнее. Снимок и восстановление должны разделяться по терминалам,
чтобы вкладки не перемешивались между приложениями.
