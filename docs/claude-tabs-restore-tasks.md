# План реализации: восстановление вкладок Claude Code в Ghostty

> **Для агентов:** ОБЯЗАТЕЛЬНЫЙ САБ-СКИЛЛ — `superpowers:subagent-driven-development`
> (рекомендуется) или `superpowers:executing-plans`. Шаги размечены чекбоксами (`- [ ]`).

**Цель:** DevDeck запоминает открытые вкладки Claude Code в Ghostty и после перезагрузки
ноутбука сам поднимает их заново — в тех же каталогах, с `claude --resume <id>`.

**Архитектура:** новый `@MainActor @Observable` синглтон `ClaudeTabsModel` в `AppDelegate`
раз в минуту снимает состояние вкладок Ghostty через AppleScript, резолвит id сессий по
заголовкам вкладок в транскриптах `~/.claude/projects/` и пишет снимок в отдельный файл.
Наблюдатель `NSWorkspace.didLaunchApplicationNotification` ловит старт Ghostty и, если
`kern.boottime` изменился с момента снимка, пересоздаёт вкладки. Вся логика решений — чистые
функции за протоколами (probe-паттерн), поэтому тесты не запускают osascript и не трогают Ghostty.

**Стек:** Swift, SwiftUI + AppKit, XCTest. Без сторонних зависимостей.

**Спека:** `docs/claude-tabs-restore-plan.md` — читать вместе с этим планом.

## Глобальные ограничения

- **Не коммитить без явной просьбы** — правило репозитория (`CLAUDE.md`). Шаги «Commit» ниже
  выполнять, только если пользователь попросил коммитить; иначе оставлять изменения в рабочем дереве.
- **Работать не в `main`.** Перед первой задачей: `git checkout -b feat/claude-tabs-restore`.
- **`.pbxproj` руками не править** — новые `.swift` подхватываются автоматически
  (`PBXFileSystemSynchronizedRootGroup`). `DevDeck/Info.plist` — обычный файл, правится напрямую.
- **Probe-паттерн обязателен:** каждая внешняя зависимость за `protocol X: Sendable` +
  `LiveX` + фейк в тестах. Тесты не запускают процессы, не читают реальный `~/.claude`,
  не вызывают osascript.
- **Все пользовательские строки — через `L10n`**, парами EN/RU. Хардкод текста в UI запрещён.
- **Команда тестов:**
  `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'`
  Префикс `DEVELOPER_DIR` обязателен: `xcode-select` указывает на CommandLineTools.
  Один класс — добавить `-only-testing:DevDeckTests/<Class>`.
- **Экранирование:** для shell — свободная функция `shellQuote(_:)` (`Support/ShellQuoting.swift`),
  для AppleScript — `AppleScriptEscaper.escape(_:)`. Свои копии не писать.
- **В AppleScript `\n` не является escape-последовательностью.** Перевод строки склеивается
  оператором `& linefeed`. Это причина, по которой ниже везде именно `& linefeed`.

---

### Task 1: Настройка `claudeTabsRestore` в конфиге

**Файлы:**
- Правка: `DevDeck/Models/Config.swift` (`struct Settings`, строки 5–87)
- Правка: `DevDeck/Store/CommandStore.swift` (рядом с `setVMMonitoring`, строка 208)
- Тест: `DevDeckTests/ClaudeTabsSettingsTests.swift` (создать)

**Интерфейсы:**
- Отдаёт наружу: `Settings.claudeTabsRestore: Bool` (по умолчанию `false`),
  `CommandStore.setClaudeTabsRestore(_ on: Bool)`.

- [ ] **Шаг 1: Написать падающий тест**

```swift
import XCTest
@testable import DevDeck

/// The restore flag is a behaviour setting like the monitoring ones: it lives in config.json,
/// decodes with a default, and survives a round trip.
final class ClaudeTabsSettingsTests: XCTestCase {

    func testDefaultsToOffWhenKeyMissing() throws {
        let json = Data(#"{"commands":[]}"#.utf8)
        let config = try JSONDecoder().decode(Config.self, from: json)
        XCTAssertFalse(config.settings.claudeTabsRestore)
    }

    func testRoundTrips() throws {
        var config = Config()
        config.settings.claudeTabsRestore = true
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(Config.self, from: data)
        XCTAssertTrue(decoded.settings.claudeTabsRestore)
    }
}
```

- [ ] **Шаг 2: Убедиться, что тест падает**

Запуск: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/ClaudeTabsSettingsTests`
Ожидание: ошибка компиляции — `value of type 'Settings' has no member 'claudeTabsRestore'`.

- [ ] **Шаг 3: Добавить поле в `Settings`**

В `struct Settings` — свойство рядом с `autoUpdateEnabled`:

```swift
    /// Restore the Claude Code tabs of a previous boot when Ghostty starts.
    var claudeTabsRestore: Bool
```

В memberwise-инициализаторе добавить параметр `claudeTabsRestore: Bool = false` и присваивание
`self.claudeTabsRestore = claudeTabsRestore`. В `CodingKeys` добавить `claudeTabsRestore`.
В `init(from:)` добавить строку:

```swift
        claudeTabsRestore = try c.decodeIfPresent(Bool.self, forKey: .claudeTabsRestore) ?? false
```

- [ ] **Шаг 4: Запустить тест — должен пройти**

Запуск: та же команда с `-only-testing:DevDeckTests/ClaudeTabsSettingsTests`
Ожидание: PASS.

- [ ] **Шаг 5: Добавить сеттер в `CommandStore`**

Рядом с `setVMMonitoring` (строка 208), по тому же образцу:

```swift
    func setClaudeTabsRestore(_ on: Bool) {
        guard config.settings.claudeTabsRestore != on else { return }
        var updated = config
        updated.settings.claudeTabsRestore = on
        persist(updated)
    }
```

- [ ] **Шаг 6: Прогнать весь набор**

Запуск: полная команда тестов без `-only-testing`.
Ожидание: PASS.

- [ ] **Шаг 7: Коммит** (только если попросили коммитить)

```bash
git add DevDeck/Models/Config.swift DevDeck/Store/CommandStore.swift DevDeckTests/ClaudeTabsSettingsTests.swift
git commit -m "feat: config flag for restoring Claude Code tabs"
```

---

### Task 2: Модель снимка и его хранилище

**Файлы:**
- Создать: `DevDeck/Models/ClaudeTabsSnapshot.swift`
- Создать: `DevDeck/ClaudeTabs/ClaudeTabsStore.swift`
- Тест: `DevDeckTests/ClaudeTabsStoreTests.swift`

**Интерфейсы:**
- Использует: `PrivateFile.applicationSupportDirectory` (`Support/PrivateFile.swift:25`).
- Отдаёт наружу: `ClaudeTabEntry(order:title:workingDirectory:sessionID:)`,
  `ClaudeTabsSnapshot(bootTime:capturedAt:tabs:)`,
  `ClaudeTabsStore(url:)` с `load() -> ClaudeTabsSnapshot?` и `save(_:) throws`.

- [ ] **Шаг 1: Написать падающий тест**

```swift
import XCTest
@testable import DevDeck

/// The snapshot file is machine state: it must round-trip, and a missing or broken file must read
/// as "no snapshot" rather than throwing — the next capture overwrites it anyway.
final class ClaudeTabsStoreTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("claude-tabs.json")
    }

    func testRoundTrip() throws {
        let url = tempURL()
        let store = ClaudeTabsStore(url: url)
        let snapshot = ClaudeTabsSnapshot(
            bootTime: Date(timeIntervalSince1970: 1_000_000),
            capturedAt: Date(timeIntervalSince1970: 1_000_100),
            tabs: [ClaudeTabEntry(order: 0, title: "✳ work", workingDirectory: "/tmp/a", sessionID: "s1"),
                   ClaudeTabEntry(order: 1, title: "✳ other", workingDirectory: "/tmp/b", sessionID: nil)])
        try store.save(snapshot)
        XCTAssertEqual(store.load(), snapshot)
    }

    func testMissingFileReadsAsNil() {
        XCTAssertNil(ClaudeTabsStore(url: tempURL()).load())
    }

    func testCorruptFileReadsAsNil() throws {
        let url = tempURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("{ not json".utf8).write(to: url)
        XCTAssertNil(ClaudeTabsStore(url: url).load())
    }
}
```

- [ ] **Шаг 2: Убедиться, что тест падает**

Запуск: `... -only-testing:DevDeckTests/ClaudeTabsStoreTests`
Ожидание: ошибка компиляции — `cannot find 'ClaudeTabsStore' in scope`.

- [ ] **Шаг 3: Написать модель**

`DevDeck/Models/ClaudeTabsSnapshot.swift`:

```swift
import Foundation

/// One Claude Code tab as it looked at capture time.
///
/// `sessionID` is optional on purpose: a tab whose session we could not resolve is still worth
/// restoring as a shell in the right directory — better than losing it.
struct ClaudeTabEntry: Codable, Equatable {
    var order: Int
    var title: String
    var workingDirectory: String
    var sessionID: String?
}

/// The tabs of one moment, stamped with the boot they belonged to.
///
/// `bootTime` is what tells a reboot ("restore these") from an ordinary Ghostty restart
/// ("leave them alone").
struct ClaudeTabsSnapshot: Codable, Equatable {
    var bootTime: Date
    var capturedAt: Date
    var tabs: [ClaudeTabEntry]
}
```

- [ ] **Шаг 4: Написать хранилище**

`DevDeck/ClaudeTabs/ClaudeTabsStore.swift`:

```swift
import Foundation

/// Reads and writes `~/Library/Application Support/DevDeck/claude-tabs.json`.
///
/// A separate file from `config.json` deliberately: this is machine state rewritten every minute,
/// and mixing it into the hand-editable config would make both worse.
struct ClaudeTabsStore {
    let url: URL

    init(url: URL = PrivateFile.applicationSupportDirectory
            .appendingPathComponent("claude-tabs.json")) {
        self.url = url
    }

    /// Missing or malformed reads as "no snapshot" — never throws. The file is disposable.
    func load() -> ClaudeTabsSnapshot? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ClaudeTabsSnapshot.self, from: data)
    }

    func save(_ snapshot: ClaudeTabsSnapshot) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: url, options: .atomic)
    }
}
```

- [ ] **Шаг 5: Запустить тест — должен пройти**

Запуск: `... -only-testing:DevDeckTests/ClaudeTabsStoreTests`
Ожидание: PASS (3 теста).

- [ ] **Шаг 6: Коммит** (только если попросили коммитить)

```bash
git add DevDeck/Models/ClaudeTabsSnapshot.swift DevDeck/ClaudeTabs/ClaudeTabsStore.swift DevDeckTests/ClaudeTabsStoreTests.swift
git commit -m "feat: snapshot model and store for Claude Code tabs"
```

---

### Task 3: Чтение вкладок Ghostty

**Файлы:**
- Создать: `DevDeck/ClaudeTabs/GhosttyTabReader.swift`
- Тест: `DevDeckTests/GhosttyTabParserTests.swift`

**Интерфейсы:**
- Использует: `ProcessTree.run(_:_:) -> String?` (`Process/ProcessTree.swift:68`).
- Отдаёт наружу: `GhosttyTab(windowID:index:title:workingDirectory:)`,
  `GhosttyTabParser.parse(_ output: String) -> [GhosttyTab]`,
  `protocol GhosttyTabReading { func readTabs() -> [GhosttyTab]? }`, `LiveGhosttyTabReader`.

- [ ] **Шаг 1: Написать падающий тест**

```swift
import XCTest
@testable import DevDeck

/// Parsing the tab-separated dump our AppleScript prints. The title is user-controlled and may
/// contain tabs itself, so the parser must not simply split into four fields.
final class GhosttyTabParserTests: XCTestCase {

    func testParsesOneTab() {
        let out = "tab-group-1\t1\t✳ work on grount\t/Users/me/work/grount\n"
        XCTAssertEqual(GhosttyTabParser.parse(out),
                       [GhosttyTab(windowID: "tab-group-1", index: 1,
                                   title: "✳ work on grount",
                                   workingDirectory: "/Users/me/work/grount")])
    }

    func testTitleMayContainTabs() {
        let out = "w1\t2\ttitle\twith\ttabs\t/tmp/x\n"
        XCTAssertEqual(GhosttyTabParser.parse(out).first?.title, "title\twith\ttabs")
        XCTAssertEqual(GhosttyTabParser.parse(out).first?.workingDirectory, "/tmp/x")
    }

    func testSkipsMalformedAndEmptyLines() {
        let out = "w1\t1\tok\t/tmp/a\n\ngarbage\nw1\tnotanumber\tbad\t/tmp/b\n"
        XCTAssertEqual(GhosttyTabParser.parse(out).map(\.workingDirectory), ["/tmp/a"])
    }

    func testParsesSeveralWindows() {
        let out = "w1\t1\ta\t/tmp/a\nw2\t1\tb\t/tmp/b\n"
        XCTAssertEqual(GhosttyTabParser.parse(out).map(\.windowID), ["w1", "w2"])
    }

    func testEmptyOutputGivesNoTabs() {
        XCTAssertTrue(GhosttyTabParser.parse("").isEmpty)
    }
}
```

- [ ] **Шаг 2: Убедиться, что тест падает**

Запуск: `... -only-testing:DevDeckTests/GhosttyTabParserTests`
Ожидание: ошибка компиляции — `cannot find 'GhosttyTabParser' in scope`.

- [ ] **Шаг 3: Написать модель, парсер и живого читателя**

`DevDeck/ClaudeTabs/GhosttyTabReader.swift`:

```swift
import Foundation

/// One tab of a running Ghostty, as reported by its AppleScript dictionary.
struct GhosttyTab: Equatable, Sendable {
    var windowID: String
    var index: Int
    var title: String
    var workingDirectory: String
}

/// Turns the tab-separated dump into tabs. Pure — the AppleScript itself is never run in tests.
enum GhosttyTabParser {
    /// Line format: `windowID \t index \t title \t workingDirectory`.
    ///
    /// The title is whatever Claude Code put in it and may contain tabs, so the first two fields
    /// are taken from the front and the directory from the back; everything between is the title.
    static func parse(_ output: String) -> [GhosttyTab] {
        output.split(separator: "\n").compactMap { line in
            let fields = String(line).components(separatedBy: "\t")
            guard fields.count >= 4,
                  let index = Int(fields[1].trimmingCharacters(in: .whitespaces)),
                  !fields[0].isEmpty,
                  !fields[fields.count - 1].isEmpty else { return nil }
            return GhosttyTab(windowID: fields[0],
                              index: index,
                              title: fields[2..<(fields.count - 1)].joined(separator: "\t"),
                              workingDirectory: fields[fields.count - 1])
        }
    }
}

/// Reads the open tabs — behind a protocol so the snapshot logic is tested without Ghostty.
protocol GhosttyTabReading: Sendable {
    /// nil when Ghostty is not running, or when AppleScript failed (Automation not granted yet).
    func readTabs() -> [GhosttyTab]?
}

/// Real implementation over `osascript`. `ghostty +new-window` is unsupported on macOS, so the
/// AppleScript dictionary is the only way in — and it is the same door `AppleScriptTabLauncher`
/// already uses (`Process/TerminalCommandRunner.swift:100`).
///
/// `nil` and `[]` are different answers: `nil` means "could not ask" (Ghostty not running, or the
/// script failed), `[]` means "asked, and there are no tabs". Callers act on that difference.
struct LiveGhosttyTabReader: GhosttyTabReading {
    func readTabs() -> [GhosttyTab]? {
        let running = !(ProcessTree.run("/usr/bin/pgrep", ["-x", "ghostty"]) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        guard running else { return nil }
        guard let out = runScript() else { return nil }
        return GhosttyTabParser.parse(out)
    }

    /// osascript is run directly rather than through `ProcessTree.run`, which returns nil only when
    /// the executable is missing: it ignores the exit status and discards stderr. `/usr/bin/osascript`
    /// always exists, so going through it would turn "Automation permission denied" — the expected
    /// first-run state — into an empty string, and an empty string parses into `[]`. That would say
    /// "no tabs are open" when the truth is "I could not ask", and the caller acts on the difference.
    private func runScript() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = Self.scriptArgs
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do {
            try process.run()
        } catch {
            DiagnosticLog.shared.log("ClaudeTabs: osascript failed to start — \(error.localizedDescription)",
                                     level: .error)
            return nil
        }
        // Drain both pipes BEFORE waiting. osascript blocks writing into a full pipe buffer
        // (~64KB), and a child that cannot write is a child that never exits — and the tab dump
        // is the one stream here that grows with every window, tab, title and path.
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorText = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            DiagnosticLog.shared.log("ClaudeTabs: reading tabs failed — \(errorText)", level: .error)
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Prints one line per tab. `tab` and `linefeed` are AppleScript's own constants — the script
    /// never has to quote them, so a title full of punctuation cannot break the format.
    static let scriptArgs: [String] = [
        "-e", "tell application \"Ghostty\"",
        "-e", "set out to \"\"",
        "-e", "repeat with w in windows",
        "-e", "repeat with t in tabs of w",
        "-e", "set out to out & (id of w) & tab & (index of t) & tab & (name of t) & tab & (working directory of focused terminal of t) & linefeed",
        "-e", "end repeat",
        "-e", "end repeat",
        "-e", "return out",
        "-e", "end tell",
    ]
}
```

- [ ] **Шаг 4: Запустить тест — должен пройти**

Запуск: `... -only-testing:DevDeckTests/GhosttyTabParserTests`
Ожидание: PASS (5 тестов).

- [ ] **Шаг 5: Коммит** (только если попросили коммитить)

```bash
git add DevDeck/ClaudeTabs/GhosttyTabReader.swift DevDeckTests/GhosttyTabParserTests.swift
git commit -m "feat: read open Ghostty tabs over AppleScript"
```

---

### Task 4: Индекс транскриптов Claude Code

**Файлы:**
- Создать: `DevDeck/ClaudeTabs/TranscriptIndex.swift`
- Тест: `DevDeckTests/TranscriptIndexTests.swift`

**Интерфейсы:**
- Отдаёт наружу: `TranscriptTitle(aiTitle:sessionID:modifiedAt:)`,
  `ClaudeProjectSlug.slug(for:) -> String`,
  `TranscriptTitleScanner.lastTitle(in: [String]) -> (aiTitle: String, sessionID: String)?`,
  `protocol TranscriptIndexing { func titles(forWorkingDirectory: String) -> [TranscriptTitle] }`,
  `LiveTranscriptIndex(projectsRoot:)`.

**Контекст, который иначе неоткуда взять:** Claude Code хранит транскрипты в
`~/.claude/projects/<slug>/<uuid>.jsonl`, где `<slug>` — путь проекта, в котором все `/`
заменены на `-` (`/Users/me/work/app` → `-Users-me-work-app`). Заголовок сессии лежит
отдельной строкой вида
`{"type":"ai-title","aiTitle":"fix-own-memory","sessionId":"4239e258-…"}`,
и строк таких может быть несколько — заголовок переписывается по ходу разговора,
поэтому берём **последнюю**.

- [ ] **Шаг 1: Написать падающий тест**

```swift
import XCTest
@testable import DevDeck

/// Finding the session id behind a tab title. The `ai-title` line is Claude Code's internal
/// format, so the scanner is deliberately forgiving: anything it cannot parse is skipped.
final class TranscriptIndexTests: XCTestCase {

    func testSlugReplacesSlashes() {
        XCTAssertEqual(ClaudeProjectSlug.slug(for: "/Users/me/work/app"), "-Users-me-work-app")
    }

    func testScannerTakesTheLastTitle() {
        let lines = [
            #"{"type":"user","cwd":"/tmp/a"}"#,
            #"{"type":"ai-title","aiTitle":"first","sessionId":"s1"}"#,
            #"{"type":"assistant"}"#,
            #"{"type":"ai-title","aiTitle":"second","sessionId":"s1"}"#,
        ]
        let found = TranscriptTitleScanner.lastTitle(in: lines)
        XCTAssertEqual(found?.aiTitle, "second")
        XCTAssertEqual(found?.sessionID, "s1")
    }

    func testScannerIgnoresBrokenLines() {
        let lines = [#"{"type":"ai-title","aiTitle":}"#, #"{"type":"ai-title","aiTitle":"ok","sessionId":"s2"}"#]
        XCTAssertEqual(TranscriptTitleScanner.lastTitle(in: lines)?.sessionID, "s2")
    }

    func testScannerReturnsNilWithoutTitleLines() {
        XCTAssertNil(TranscriptTitleScanner.lastTitle(in: [#"{"type":"user"}"#]))
    }

    func testLiveIndexReadsProjectDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("-tmp-proj")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data(#"{"type":"ai-title","aiTitle":"alpha","sessionId":"s1"}"#.utf8)
            .write(to: project.appendingPathComponent("s1.jsonl"))

        let index = LiveTranscriptIndex(projectsRoot: root)
        XCTAssertEqual(index.titles(forWorkingDirectory: "/tmp/proj").map(\.sessionID), ["s1"])
    }

    func testLiveIndexFallsBackToScanningWhenTheSlugDoesNotMatch() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("renamed-by-some-future-claude")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data((#"{"type":"user","cwd":"/tmp/proj"}"# + "\n"
                  + #"{"type":"ai-title","aiTitle":"alpha","sessionId":"s9"}"#).utf8)
            .write(to: project.appendingPathComponent("s9.jsonl"))

        let index = LiveTranscriptIndex(projectsRoot: root)
        XCTAssertEqual(index.titles(forWorkingDirectory: "/tmp/proj").map(\.sessionID), ["s9"])
    }

    func testLiveIndexReturnsNothingForUnknownDirectory() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertTrue(LiveTranscriptIndex(projectsRoot: root).titles(forWorkingDirectory: "/nope").isEmpty)
    }
}
```

- [ ] **Шаг 2: Убедиться, что тест падает**

Запуск: `... -only-testing:DevDeckTests/TranscriptIndexTests`
Ожидание: ошибка компиляции — `cannot find 'ClaudeProjectSlug' in scope`.

- [ ] **Шаг 3: Написать индекс**

`DevDeck/ClaudeTabs/TranscriptIndex.swift`:

```swift
import Foundation

/// A session title recorded in a transcript, with the file's mtime for ordering.
struct TranscriptTitle: Equatable, Sendable {
    var aiTitle: String
    var sessionID: String
    var modifiedAt: Date
}

/// Claude Code names a project directory after its path with every "/" turned into "-".
enum ClaudeProjectSlug {
    static func slug(for path: String) -> String {
        path.replacingOccurrences(of: "/", with: "-")
    }
}

/// Pulls the session title out of transcript lines.
///
/// Deliberately lenient: `ai-title` is Claude Code's internal format, and a change there must
/// degrade into "title not found" rather than a crash or a wrong session id.
enum TranscriptTitleScanner {
    static func lastTitle(in lines: [String]) -> (aiTitle: String, sessionID: String)? {
        for line in lines.reversed() where line.contains("\"type\":\"ai-title\"") {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let title = object["aiTitle"] as? String,
                  let sessionID = object["sessionId"] as? String,
                  !title.isEmpty, !sessionID.isEmpty else { continue }
            return (title, sessionID)
        }
        return nil
    }
}

/// Titles known for a working directory — behind a protocol so the resolver is tested with a fake.
protocol TranscriptIndexing: Sendable {
    /// Newest transcript first.
    func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle]
}

/// Scans `~/.claude/projects`. Results are cached per (file, mtime), so only the first pass over a
/// large transcript is expensive and the once-a-minute snapshot stays cheap.
final class LiveTranscriptIndex: TranscriptIndexing, @unchecked Sendable {
    private let projectsRoot: URL
    private let lock = NSLock()
    private var cache: [URL: (modifiedAt: Date, title: TranscriptTitle?)] = [:]

    init(projectsRoot: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects")) {
        self.projectsRoot = projectsRoot
    }

    func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle] {
        guard let directory = projectDirectory(for: workingDirectory),
              let files = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return [] }
        return files
            .filter { $0.pathExtension == "jsonl" }
            .compactMap { title(of: $0) }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// The slug is the fast path. If Claude ever changes how it names project directories, fall back
    /// to scanning every project and matching the `cwd` its transcripts record — slower, but the
    /// feature degrades into a delay rather than into silence.
    private func projectDirectory(for workingDirectory: String) -> URL? {
        let bySlug = projectsRoot.appendingPathComponent(ClaudeProjectSlug.slug(for: workingDirectory))
        if FileManager.default.fileExists(atPath: bySlug.path) { return bySlug }
        guard let projects = try? FileManager.default.contentsOfDirectory(
                at: projectsRoot, includingPropertiesForKeys: nil) else { return nil }
        let needle = "\"cwd\":\"\(workingDirectory)\""
        return projects.first { project in
            guard let files = try? FileManager.default.contentsOfDirectory(
                    at: project, includingPropertiesForKeys: nil) else { return false }
            return files.contains { file in
                file.pathExtension == "jsonl"
                    && ((try? String(contentsOf: file, encoding: .utf8))?.contains(needle) ?? false)
            }
        }
    }

    private func title(of file: URL) -> TranscriptTitle? {
        let modifiedAt = (try? file.resourceValues(forKeys: [.contentModificationDateKey])
            .contentModificationDate) ?? .distantPast
        lock.lock()
        if let cached = cache[file], cached.modifiedAt == modifiedAt {
            lock.unlock()
            return cached.title
        }
        lock.unlock()

        var result: TranscriptTitle?
        if let content = try? String(contentsOf: file, encoding: .utf8),
           let found = TranscriptTitleScanner.lastTitle(in: content.components(separatedBy: "\n")) {
            result = TranscriptTitle(aiTitle: found.aiTitle, sessionID: found.sessionID, modifiedAt: modifiedAt)
        }
        lock.lock()
        cache[file] = (modifiedAt, result)
        lock.unlock()
        return result
    }
}
```

- [ ] **Шаг 4: Запустить тест — должен пройти**

Запуск: `... -only-testing:DevDeckTests/TranscriptIndexTests`
Ожидание: PASS (7 тестов).

- [ ] **Шаг 5: Коммит** (только если попросили коммитить)

```bash
git add DevDeck/ClaudeTabs/TranscriptIndex.swift DevDeckTests/TranscriptIndexTests.swift
git commit -m "feat: index Claude Code session titles from transcripts"
```

---

### Task 5: Резолвер сессий

**Файлы:**
- Создать: `DevDeck/ClaudeTabs/SessionResolver.swift`
- Тест: `DevDeckTests/SessionResolverTests.swift`

**Интерфейсы:**
- Использует: `GhosttyTab` (задача 3), `TranscriptTitle` (задача 4), `ClaudeTabEntry` (задача 2).
- Отдаёт наружу: `SessionResolver.normalize(_ title: String) -> String`,
  `SessionResolver.resolve(tabs: [GhosttyTab], titlesByDirectory: [String: [TranscriptTitle]]) -> [ClaudeTabEntry]`.

- [ ] **Шаг 1: Написать падающий тест**

```swift
import XCTest
@testable import DevDeck

/// Matching a Ghostty tab to the Claude session running in it. Pure — no Ghostty, no filesystem.
final class SessionResolverTests: XCTestCase {

    private func title(_ text: String, _ id: String, _ seconds: TimeInterval) -> TranscriptTitle {
        TranscriptTitle(aiTitle: text, sessionID: id, modifiedAt: Date(timeIntervalSince1970: seconds))
    }

    private func tab(_ index: Int, _ title: String, _ cwd: String) -> GhosttyTab {
        GhosttyTab(windowID: "w1", index: index, title: title, workingDirectory: cwd)
    }

    func testStripsStatusGlyph() {
        XCTAssertEqual(SessionResolver.normalize("✳ fix-own-memory"), "fix-own-memory")
        XCTAssertEqual(SessionResolver.normalize("◐  Ghostty session"), "Ghostty session")
    }

    func testExactMatch() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "✳ alpha", "/tmp/a")],
            titlesByDirectory: ["/tmp/a": [title("alpha", "s1", 10)]])
        XCTAssertEqual(entries.map(\.sessionID), ["s1"])
    }

    func testPrefixMatchForTruncatedTitle() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "✳ long title that got", "/tmp/a")],
            titlesByDirectory: ["/tmp/a": [title("long title that got cut off", "s1", 10)]])
        XCTAssertEqual(entries.map(\.sessionID), ["s1"])
    }

    func testTwoTabsWithTheSameTitleGetDifferentSessions() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "✳ same", "/tmp/a"), tab(2, "✳ same", "/tmp/a")],
            titlesByDirectory: ["/tmp/a": [title("same", "newer", 20), title("same", "older", 10)]])
        XCTAssertEqual(entries.map(\.sessionID), ["newer", "older"])
    }

    func testUnresolvedTabIsKeptWithoutSession() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "zsh", "/tmp/a")],
            titlesByDirectory: [:])
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].sessionID)
        XCTAssertEqual(entries[0].workingDirectory, "/tmp/a")
    }

    /// The prefix stage must not fire on an empty needle: `anything.hasPrefix("")` is true, so an
    /// unguarded prefix match would bind a glyph-only tab title to the first session in its directory.
    /// Verified to FAIL when `!wanted.isEmpty &&` is removed — a test that passes either way pins nothing.
    func testGlyphOnlyTitleMatchesNothingEvenWithCandidatesPresent() {
        let entries = SessionResolver.resolve(
            tabs: [tab(1, "✳", "/tmp/a")],
            titlesByDirectory: ["/tmp/a": [title("alpha", "s1", 10)]])
        XCTAssertEqual(entries.count, 1)
        XCTAssertNil(entries[0].sessionID)
    }

    func testNormalizeReturnsEmptyForAGlyphOnlyTitle() {
        XCTAssertEqual(SessionResolver.normalize("✳"), "")
        XCTAssertEqual(SessionResolver.normalize("  ◐  "), "")
    }

    func testOrderFollowsWindowThenTabIndex() {
        let tabs = [GhosttyTab(windowID: "w2", index: 1, title: "c", workingDirectory: "/tmp/c"),
                    GhosttyTab(windowID: "w1", index: 2, title: "b", workingDirectory: "/tmp/b"),
                    GhosttyTab(windowID: "w1", index: 1, title: "a", workingDirectory: "/tmp/a")]
        let entries = SessionResolver.resolve(tabs: tabs, titlesByDirectory: [:])
        XCTAssertEqual(entries.map(\.order), [0, 1, 2])
        XCTAssertEqual(entries.map(\.workingDirectory), ["/tmp/a", "/tmp/b", "/tmp/c"])
    }
}
```

- [ ] **Шаг 2: Убедиться, что тест падает**

Запуск: `... -only-testing:DevDeckTests/SessionResolverTests`
Ожидание: ошибка компиляции — `cannot find 'SessionResolver' in scope`.

- [ ] **Шаг 3: Написать резолвер**

`DevDeck/ClaudeTabs/SessionResolver.swift`:

```swift
import Foundation

/// Matches open Ghostty tabs to Claude Code sessions by their titles. Pure by design: this is the
/// one piece of guesswork in the feature, so it has to be exhaustively testable.
enum SessionResolver {

    /// Claude Code prefixes the tab title with a status glyph ("✳ ", "◐ "). Strip any leading run
    /// of non-alphanumerics so the title matches the `aiTitle` recorded in the transcript.
    static func normalize(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let start = trimmed.firstIndex(where: { $0.isLetter || $0.isNumber }) else { return "" }
        return String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Tabs in display order, each carrying the session we could resolve for it.
    ///
    /// A session already claimed by an earlier tab is removed from the candidates: that is what
    /// keeps two tabs with the same title in the same directory from collapsing onto one session.
    static func resolve(tabs: [GhosttyTab],
                        titlesByDirectory: [String: [TranscriptTitle]]) -> [ClaudeTabEntry] {
        let ordered = tabs.sorted { ($0.windowID, $0.index) < ($1.windowID, $1.index) }
        var claimed: Set<String> = []
        return ordered.enumerated().map { position, tab in
            let wanted = normalize(tab.title)
            let candidates = (titlesByDirectory[tab.workingDirectory] ?? [])
                .filter { !claimed.contains($0.sessionID) }
            let match = candidates.first { normalize($0.aiTitle) == wanted }
                ?? candidates.first { !wanted.isEmpty && normalize($0.aiTitle).hasPrefix(wanted) }
            if let match { claimed.insert(match.sessionID) }
            return ClaudeTabEntry(order: position,
                                  title: tab.title,
                                  workingDirectory: tab.workingDirectory,
                                  sessionID: match?.sessionID)
        }
    }
}
```

- [ ] **Шаг 4: Запустить тест — должен пройти**

Запуск: `... -only-testing:DevDeckTests/SessionResolverTests`
Ожидание: PASS (8 тестов).

- [ ] **Шаг 5: Коммит** (только если попросили коммитить)

```bash
git add DevDeck/ClaudeTabs/SessionResolver.swift DevDeckTests/SessionResolverTests.swift
git commit -m "feat: resolve Ghostty tab titles to Claude session ids"
```

---

### Task 6: Планировщик восстановления и время загрузки

**Файлы:**
- Создать: `DevDeck/ClaudeTabs/BootTime.swift`
- Создать: `DevDeck/ClaudeTabs/RestorePlanner.swift`
- Тест: `DevDeckTests/RestorePlannerTests.swift`

**Интерфейсы:**
- Использует: `ClaudeTabsSnapshot`, `ClaudeTabEntry` (задача 2).
- Отдаёт наружу: `protocol BootTimeProviding { func bootTime() -> Date }`, `LiveBootTime`,
  `RestoreAction` (`.inputText(cwd:sessionID:)` / `.newTab(cwd:sessionID:)`),
  `RestoreDecision` (`.skip(reason:)` / `.restore([RestoreAction])`),
  `RestorePlanner.maxTabs: Int`,
  `RestorePlanner.decide(snapshot:enabled:currentBootTime:restoredBootTime:openTabCount:) -> RestoreDecision`.

- [ ] **Шаг 1: Написать падающий тест**

```swift
import XCTest
@testable import DevDeck

/// Deciding whether this Ghostty launch is the one that should restore tabs — and what to do.
/// Every branch here is a way to annoy the user (duplicate tabs, typing into someone else's
/// shell, a wall of processes), so all of them are pinned down.
final class RestorePlannerTests: XCTestCase {

    private let lastBoot = Date(timeIntervalSince1970: 1_000)
    private let thisBoot = Date(timeIntervalSince1970: 2_000)

    private func snapshot(_ count: Int, boot: Date? = nil) -> ClaudeTabsSnapshot {
        ClaudeTabsSnapshot(
            bootTime: boot ?? lastBoot,
            capturedAt: Date(timeIntervalSince1970: 1_500),
            tabs: (0..<count).map {
                ClaudeTabEntry(order: $0, title: "t\($0)", workingDirectory: "/tmp/\($0)", sessionID: "s\($0)")
            })
    }

    private func decide(_ snap: ClaudeTabsSnapshot?, enabled: Bool = true,
                        restored: Date? = nil, openTabs: Int = 1) -> RestoreDecision {
        RestorePlanner.decide(snapshot: snap, enabled: enabled, currentBootTime: thisBoot,
                              restoredBootTime: restored, openTabCount: openTabs)
    }

    func testRestoresAfterReboot() {
        XCTAssertEqual(decide(snapshot(2)),
                       .restore([.inputText(cwd: "/tmp/0", sessionID: "s0"),
                                 .newTab(cwd: "/tmp/1", sessionID: "s1")]))
    }

    func testSkipsWhenDisabled() {
        guard case .skip = decide(snapshot(2), enabled: false) else { return XCTFail("expected skip") }
    }

    func testSkipsWithoutSnapshot() {
        guard case .skip = decide(nil) else { return XCTFail("expected skip") }
    }

    func testSkipsOnEmptySnapshot() {
        guard case .skip = decide(snapshot(0)) else { return XCTFail("expected skip") }
    }

    func testSkipsWhenGhosttyMerelyRestartedInTheSameBoot() {
        guard case .skip = decide(snapshot(2, boot: thisBoot)) else { return XCTFail("expected skip") }
    }

    func testSkipsWhenAlreadyRestoredInThisBoot() {
        guard case .skip = decide(snapshot(2), restored: thisBoot) else { return XCTFail("expected skip") }
    }

    func testAllNewTabsWhenGhosttyAlreadyHasSeveralTabs() {
        guard case let .restore(actions) = decide(snapshot(2), openTabs: 3) else {
            return XCTFail("expected restore")
        }
        XCTAssertEqual(actions, [.newTab(cwd: "/tmp/0", sessionID: "s0"),
                                 .newTab(cwd: "/tmp/1", sessionID: "s1")])
    }

    func testCapsTheNumberOfTabs() {
        guard case let .restore(actions) = decide(snapshot(50)) else { return XCTFail("expected restore") }
        XCTAssertEqual(actions.count, RestorePlanner.maxTabs)
    }
}
```

- [ ] **Шаг 2: Убедиться, что тест падает**

Запуск: `... -only-testing:DevDeckTests/RestorePlannerTests`
Ожидание: ошибка компиляции — `cannot find 'RestorePlanner' in scope`.

- [ ] **Шаг 3: Написать поставщика времени загрузки**

`DevDeck/ClaudeTabs/BootTime.swift`:

```swift
import Foundation

/// When the machine last booted — behind a protocol so the planner is tested with fixed dates.
protocol BootTimeProviding: Sendable {
    func bootTime() -> Date
}

/// `kern.boottime` is constant for the life of a boot, which is exactly what distinguishes
/// "the laptop restarted" (restore the tabs) from "Ghostty restarted" (leave them alone).
struct LiveBootTime: BootTimeProviding {
    func bootTime() -> Date {
        var value = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &value, &size, nil, 0) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000)
    }
}
```

- [ ] **Шаг 4: Написать планировщик**

`DevDeck/ClaudeTabs/RestorePlanner.swift`:

```swift
import Foundation

/// One thing to do to Ghostty when restoring.
enum RestoreAction: Equatable, Sendable {
    /// Type into the terminal Ghostty already opened for itself.
    case inputText(cwd: String, sessionID: String?)
    /// Open a fresh tab configured with the directory and the command.
    case newTab(cwd: String, sessionID: String?)
}

enum RestoreDecision: Equatable {
    case skip(reason: String)
    case restore([RestoreAction])
}

/// Decides whether this Ghostty launch is the post-reboot one, and what to open. Pure.
enum RestorePlanner {

    /// Never restore more than this in one go. If resolution ever goes wrong, the blast radius
    /// should be a screenful of tabs, not a hundred claude processes.
    static let maxTabs = 20

    static func decide(snapshot: ClaudeTabsSnapshot?,
                       enabled: Bool,
                       currentBootTime: Date,
                       restoredBootTime: Date?,
                       openTabCount: Int) -> RestoreDecision {
        guard enabled else { return .skip(reason: "restore is off") }
        guard let snapshot else { return .skip(reason: "no snapshot") }
        guard !snapshot.tabs.isEmpty else { return .skip(reason: "snapshot is empty") }
        guard snapshot.bootTime != currentBootTime else {
            return .skip(reason: "same boot — Ghostty restarted, the machine did not")
        }
        guard restoredBootTime != currentBootTime else {
            return .skip(reason: "already restored in this boot")
        }

        // Reuse the empty tab Ghostty opens for itself, but only when it is provably the only one.
        // If macOS restored windows of its own, typing into someone else's tab is worse than
        // leaving one blank tab behind.
        let reuseFirstTab = openTabCount == 1
        let actions = snapshot.tabs
            .sorted { $0.order < $1.order }
            .prefix(maxTabs)
            .enumerated()
            .map { offset, entry -> RestoreAction in
                offset == 0 && reuseFirstTab
                    ? .inputText(cwd: entry.workingDirectory, sessionID: entry.sessionID)
                    : .newTab(cwd: entry.workingDirectory, sessionID: entry.sessionID)
            }
        return .restore(actions)
    }
}
```

- [ ] **Шаг 5: Запустить тест — должен пройти**

Запуск: `... -only-testing:DevDeckTests/RestorePlannerTests`
Ожидание: PASS (8 тестов).

- [ ] **Шаг 6: Коммит** (только если попросили коммитить)

```bash
git add DevDeck/ClaudeTabs/BootTime.swift DevDeck/ClaudeTabs/RestorePlanner.swift DevDeckTests/RestorePlannerTests.swift
git commit -m "feat: plan which tabs to restore after a reboot"
```

---

### Task 7: Исполнитель восстановления

**Файлы:**
- Создать: `DevDeck/ClaudeTabs/TabRestorer.swift`
- Правка: `DevDeck/Info.plist`
- Тест: `DevDeckTests/TabRestorerTests.swift`

**Интерфейсы:**
- Использует: `RestoreAction` (задача 6), `shellQuote(_:)` (`Support/ShellQuoting.swift`),
  `AppleScriptEscaper.escape(_:)` (`Process/AppleScriptEscaper.swift`).
- Отдаёт наружу: `RestoreCommand.text(cwd:sessionID:) -> String`,
  `RestoreScript.newTabArgs(cwd:text:) -> [String]`, `RestoreScript.inputTextArgs(text:) -> [String]`,
  `protocol AppleScriptRunning { func run(_ args: [String]) -> Bool }`, `LiveAppleScriptRunner`,
  `TabRestorer(runner:stepDelay:)` с `func restore(_ actions: [RestoreAction]) async -> Bool`.

- [ ] **Шаг 1: Написать падающий тест**

```swift
import XCTest
@testable import DevDeck

/// Building the command and the AppleScript that puts it into Ghostty.
/// The scripts are asserted as strings — this is the layer where a quoting slip would run
/// arbitrary text as a command.
final class TabRestorerTests: XCTestCase {

    final class FakeAppleScriptRunner: AppleScriptRunning, @unchecked Sendable {
        var calls: [[String]] = []
        var result = true
        func run(_ args: [String]) -> Bool { calls.append(args); return result }
    }

    func testCommandResumesTheSession() {
        XCTAssertEqual(RestoreCommand.text(cwd: "/tmp/a", sessionID: "s1"),
                       "cd '/tmp/a' && claude --resume s1")
    }

    func testCommandWithoutSessionOnlyChangesDirectory() {
        XCTAssertEqual(RestoreCommand.text(cwd: "/tmp/a", sessionID: nil), "cd '/tmp/a'")
    }

    func testCommandQuotesAwkwardPaths() {
        XCTAssertEqual(RestoreCommand.text(cwd: "/tmp/it's here", sessionID: nil),
                       #"cd '/tmp/it'\''s here'"#)
    }

    /// AppleScript has no "\n" escape — the newline has to be concatenated as `linefeed`,
    /// or the command is typed but never submitted.
    func testNewTabScriptAppendsLinefeedNotBackslashN() {
        let args = RestoreScript.newTabArgs(cwd: "/tmp/a", text: "cd '/tmp/a'")
        XCTAssertTrue(args.contains { $0.contains("& linefeed") })
        XCTAssertFalse(args.contains { $0.contains("\\n\"") })
    }

    func testNewTabScriptSetsDirectoryAndInput() {
        let args = RestoreScript.newTabArgs(cwd: "/tmp/a", text: "cd '/tmp/a'")
        XCTAssertTrue(args.contains("set initial working directory of cfg to \"/tmp/a\""))
        XCTAssertTrue(args.contains("new tab with configuration cfg"))
    }

    func testInputTextScriptTargetsTheFrontWindow() {
        let args = RestoreScript.inputTextArgs(text: "cd '/tmp/a'")
        XCTAssertTrue(args.contains { $0.contains("focused terminal of selected tab of front window") })
    }

    func testRestorerRunsOneScriptPerAction() async {
        let runner = FakeAppleScriptRunner()
        let restorer = TabRestorer(runner: runner, stepDelay: .zero)
        let ok = await restorer.restore([.inputText(cwd: "/tmp/a", sessionID: "s1"),
                                         .newTab(cwd: "/tmp/b", sessionID: nil)])
        XCTAssertTrue(ok)
        XCTAssertEqual(runner.calls.count, 2)
        XCTAssertTrue(runner.calls[0].contains { $0.contains("input text") })
        XCTAssertTrue(runner.calls[1].contains("new tab with configuration cfg"))
    }

    func testRestorerReportsFailure() async {
        let runner = FakeAppleScriptRunner()
        runner.result = false
        let ok = await TabRestorer(runner: runner, stepDelay: .zero)
            .restore([.newTab(cwd: "/tmp/a", sessionID: nil)])
        XCTAssertFalse(ok)
    }
}
```

- [ ] **Шаг 2: Убедиться, что тест падает**

Запуск: `... -only-testing:DevDeckTests/TabRestorerTests`
Ожидание: ошибка компиляции — `cannot find 'RestoreCommand' in scope`.

- [ ] **Шаг 3: Написать исполнителя**

`DevDeck/ClaudeTabs/TabRestorer.swift`:

```swift
import Foundation

/// The line typed into a live interactive zsh.
///
/// A tab whose session did not resolve still lands in the right directory: a shell in the right
/// place is a far better failure than a lost tab.
enum RestoreCommand {
    static func text(cwd: String, sessionID: String?) -> String {
        guard let sessionID else { return "cd \(shellQuote(cwd))" }
        // The session id is read from a transcript with a deliberately lenient parser and ends up
        // TYPED INTO A LIVE SHELL and executed, so it is untrusted input and gets the same quoting
        // the directory does. AppleScript escaping would not help: it guards the script literal,
        // not the shell that parses the text afterwards.
        return "cd \(shellQuote(cwd)) && claude --resume \(shellQuote(sessionID))"
    }
}

/// The osascript arguments for each kind of action.
///
/// Note `& linefeed`: AppleScript string literals have no "\n" escape, so a backslash-n would be
/// typed literally and the command would sit on the prompt unsubmitted.
enum RestoreScript {
    static func newTabArgs(cwd: String, text: String) -> [String] {
        [
            "-e", "tell application \"Ghostty\"",
            "-e", "set cfg to new surface configuration",
            "-e", "set initial working directory of cfg to \"\(AppleScriptEscaper.escape(cwd))\"",
            "-e", "set initial input of cfg to \"\(AppleScriptEscaper.escape(text))\" & linefeed",
            // `try` swallows Ghostty's spurious -1708, which arrives even though the tab was created.
            "-e", "try",
            "-e", "new tab with configuration cfg",
            "-e", "end try",
            "-e", "end tell",
        ]
    }

    /// No `try` here, unlike `newTabArgs`: that one swallows Ghostty's documented spurious -1708,
    /// which arrives even when the tab was created. There is no such quirk for `input text`, and
    /// swallowing its errors would let osascript exit 0 for a tab nothing was typed into — a
    /// restore that reports success and did nothing.
    static func inputTextArgs(text: String) -> [String] {
        [
            "-e", "tell application \"Ghostty\"",
            "-e", "input text (\"\(AppleScriptEscaper.escape(text))\" & linefeed) to focused terminal of selected tab of front window",
            "-e", "end tell",
        ]
    }
}

/// Runs osascript — behind a protocol so the restorer is tested without touching Ghostty.
protocol AppleScriptRunning: Sendable {
    func run(_ args: [String]) -> Bool
}

struct LiveAppleScriptRunner: AppleScriptRunning {
    func run(_ args: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = args
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            DiagnosticLog.shared.log("ClaudeTabs: osascript failed to start — \(error.localizedDescription)",
                                     level: .error)
            return false
        }
        // Drain the pipe BEFORE waiting. Only stderr is piped here and osascript's stderr is a line
        // or two, so this is not the deadlock the tab reader had — but one ordering across the
        // codebase beats two that differ by an unstated precondition.
        let message = String(data: errors.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            DiagnosticLog.shared.log("ClaudeTabs: AppleScript error — \(message)", level: .error)
            return false
        }
        return true
    }
}

/// Replays a restore plan into Ghostty, pacing itself so nine claude processes do not all start
/// in the same second.
struct TabRestorer {
    let runner: AppleScriptRunning
    let stepDelay: Duration

    init(runner: AppleScriptRunning = LiveAppleScriptRunner(), stepDelay: Duration = .milliseconds(700)) {
        self.runner = runner
        self.stepDelay = stepDelay
    }

    /// false if any step failed — the caller surfaces it once, rather than per tab.
    @discardableResult
    func restore(_ actions: [RestoreAction]) async -> Bool {
        var allSucceeded = true
        for (offset, action) in actions.enumerated() {
            if offset > 0, stepDelay > .zero {
                try? await Task.sleep(for: stepDelay)
            }
            let args: [String]
            switch action {
            case let .inputText(cwd, sessionID):
                args = RestoreScript.inputTextArgs(text: RestoreCommand.text(cwd: cwd, sessionID: sessionID))
            case let .newTab(cwd, sessionID):
                args = RestoreScript.newTabArgs(cwd: cwd,
                                                text: RestoreCommand.text(cwd: cwd, sessionID: sessionID))
            }
            if !runner.run(args) { allSucceeded = false }
        }
        return allSucceeded
    }
}
```

- [ ] **Шаг 4: Добавить строку разрешения в `Info.plist`**

Рядом с `NSLocalNetworkUsageDescription` добавить (macOS показывает её в запросе Automation):

```xml
	<key>NSAppleEventsUsageDescription</key>
	<string>DevDeck asks Ghostty to reopen the Claude Code tabs you had before the last restart.</string>
```

- [ ] **Шаг 5: Запустить тест — должен пройти**

Запуск: `... -only-testing:DevDeckTests/TabRestorerTests`
Ожидание: PASS (8 тестов).

- [ ] **Шаг 6: Коммит** (только если попросили коммитить)

```bash
git add DevDeck/ClaudeTabs/TabRestorer.swift DevDeck/Info.plist DevDeckTests/TabRestorerTests.swift
git commit -m "feat: reopen Claude Code tabs in Ghostty over AppleScript"
```

---

### Task 8: Модель `ClaudeTabsModel` и проводка в приложении

**Файлы:**
- Создать: `DevDeck/ClaudeTabs/ClaudeTabsModel.swift`
- Правка: `DevDeck/AppDelegate.swift` (создание синглтонов — строки 8–20, старт — `applicationDidFinishLaunching`)
- Тест: `DevDeckTests/SnapshotPolicyTests.swift`

**Интерфейсы:**
- Использует: `GhosttyTabReading`, `TranscriptIndexing`, `SessionResolver`, `ClaudeTabsStore`,
  `RestorePlanner`, `BootTimeProviding`, `TabRestorer`, `CommandStore`.
- Отдаёт наружу: `SnapshotPolicy.shouldPersist(_:) -> Bool`,
  `ClaudeTabsModel(reader:index:store:bootTime:restorer:)` с
  `snapshot: ClaudeTabsSnapshot?`, `lastError: String?`,
  `func start(isEnabled:)`, `func captureNow()`, `func restoreNow()`.

- [ ] **Шаг 1: Написать падающий тест**

```swift
import XCTest
@testable import DevDeck

/// The one rule that keeps the feature from destroying itself: quitting Ghostty normally leaves
/// zero tabs, and writing that empty result would wipe the snapshot right before the shutdown
/// the whole feature exists for.
final class SnapshotPolicyTests: XCTestCase {

    func testEmptyResultIsNotPersisted() {
        XCTAssertFalse(SnapshotPolicy.shouldPersist([]))
    }

    func testNonEmptyResultIsPersisted() {
        let entries = [ClaudeTabEntry(order: 0, title: "t", workingDirectory: "/tmp", sessionID: "s")]
        XCTAssertTrue(SnapshotPolicy.shouldPersist(entries))
    }
}
```

- [ ] **Шаг 2: Убедиться, что тест падает**

Запуск: `... -only-testing:DevDeckTests/SnapshotPolicyTests`
Ожидание: ошибка компиляции — `cannot find 'SnapshotPolicy' in scope`.

- [ ] **Шаг 3: Написать модель**

`DevDeck/ClaudeTabs/ClaudeTabsModel.swift`:

```swift
import AppKit

enum SnapshotPolicy {
    /// Never overwrite a good snapshot with an empty one.
    static func shouldPersist(_ entries: [ClaudeTabEntry]) -> Bool { !entries.isEmpty }
}

/// Owns the capture timer, the Ghostty-launch observer and the restore flow.
///
/// Everything it decides lives in `SessionResolver`, `RestorePlanner` and `SnapshotPolicy`;
/// this type is deliberately only wiring, so the untestable parts stay thin.
@MainActor
@Observable
final class ClaudeTabsModel {

    /// UserDefaults, not the config: this is execution state, and it must not travel with a
    /// hand-edited config.json.
    private static let restoredBootTimeKey = "claudeTabs.restoredBootTime"

    private(set) var snapshot: ClaudeTabsSnapshot?
    private(set) var lastError: String?

    private let reader: GhosttyTabReading
    private let index: TranscriptIndexing
    private let store: ClaudeTabsStore
    private let bootTime: BootTimeProviding
    private let restorer: TabRestorer
    private var isEnabled: () -> Bool = { false }
    private var timer: Timer?

    init(reader: GhosttyTabReading = LiveGhosttyTabReader(),
         index: TranscriptIndexing = LiveTranscriptIndex(),
         store: ClaudeTabsStore = ClaudeTabsStore(),
         bootTime: BootTimeProviding = LiveBootTime(),
         restorer: TabRestorer = TabRestorer()) {
        self.reader = reader
        self.index = index
        self.store = store
        self.bootTime = bootTime
        self.restorer = restorer
        self.snapshot = store.load()
    }

    func start(isEnabled: @escaping () -> Bool) {
        self.isEnabled = isEnabled

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.captureIfEnabled() }
        }

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification,
                           object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard app?.bundleIdentifier == "com.mitchellh.ghostty" else { return }
            Task { @MainActor in await self?.restoreAfterGhosttyLaunch() }
        }
        center.addObserver(forName: NSWorkspace.willPowerOffNotification,
                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.captureIfEnabled() }
        }
    }

    func captureNow() { capture() }

    private func captureIfEnabled() {
        guard isEnabled() else { return }
        capture()
    }

    private func capture() {
        guard let tabs = reader.readTabs(), !tabs.isEmpty else { return }
        var titles: [String: [TranscriptTitle]] = [:]
        for directory in Set(tabs.map(\.workingDirectory)) {
            titles[directory] = index.titles(forWorkingDirectory: directory)
        }
        let entries = SessionResolver.resolve(tabs: tabs, titlesByDirectory: titles)
        guard SnapshotPolicy.shouldPersist(entries) else { return }

        let fresh = ClaudeTabsSnapshot(bootTime: bootTime.bootTime(), capturedAt: Date(), tabs: entries)
        do {
            try store.save(fresh)
            snapshot = fresh
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            DiagnosticLog.shared.log("ClaudeTabs: snapshot write failed — \(error.localizedDescription)",
                                     level: .error)
        }
    }

    /// Ghostty needs a moment to put up its first window before we can talk to it.
    private func restoreAfterGhosttyLaunch() async {
        try? await Task.sleep(for: .milliseconds(1500))
        await runRestore()
    }

    func restoreNow() { Task { await runRestore(force: true) } }

    private func runRestore(force: Bool = false) async {
        let currentBoot = bootTime.bootTime()
        let restored = UserDefaults.standard.object(forKey: Self.restoredBootTimeKey) as? Date
        let decision = RestorePlanner.decide(snapshot: store.load(),
                                             enabled: force || isEnabled(),
                                             currentBootTime: currentBoot,
                                             restoredBootTime: force ? nil : restored,
                                             openTabCount: reader.readTabs()?.count ?? 0)
        switch decision {
        case let .skip(reason):
            DiagnosticLog.shared.log("ClaudeTabs: not restoring — \(reason)")
        case let .restore(actions):
            DiagnosticLog.shared.log("ClaudeTabs: restoring \(actions.count) tab(s)")
            let ok = await restorer.restore(actions)
            UserDefaults.standard.set(currentBoot, forKey: Self.restoredBootTimeKey)
            lastError = ok ? nil : L10n.claudeTabsRestoreFailed
        }
    }
}
```

- [ ] **Шаг 4: Добавить строку, которую использует модель**

`ClaudeTabsModel` ссылается на `L10n.claudeTabsRestoreFailed`, поэтому строка добавляется здесь,
а не в задаче 9 — иначе задача 8 не соберётся:

```swift
    static var claudeTabsRestoreFailed: String {
        t("Ghostty refused the request — check Automation permission in System Settings › Privacy & Security.",
          "Ghostty отклонил запрос — проверь разрешение Automation в «Системных настройках › Конфиденциальность».")
    }
```

- [ ] **Шаг 5: Провести модель в `AppDelegate`**

Рядом с остальными синглтонами (`AppDelegate.swift:8–13`):

```swift
    let claudeTabs = ClaudeTabsModel()
```

В конце `applicationDidFinishLaunching`, после `store.start()`:

```swift
        // Snapshots of the Claude Code tabs, and the post-reboot restore.
        // The flag is read live from the config so switching it takes effect without a relaunch.
        claudeTabs.start(isEnabled: { [weak store] in store?.config.settings.claudeTabsRestore ?? false })
```

И там же, где остальные модели попадают в SwiftUI-окружение, добавить `.environment(claudeTabs)`.

В `applicationWillTerminate` — последний снимок перед выходом, рядом с остальной уборкой:

```swift
        claudeTabs.captureNow()
```

- [ ] **Шаг 6: Запустить тест и весь набор**

Запуск: `... -only-testing:DevDeckTests/SnapshotPolicyTests`, затем полная команда без `-only-testing`.
Ожидание: PASS.

- [ ] **Шаг 7: Коммит** (только если попросили коммитить)

```bash
git add DevDeck/ClaudeTabs/ClaudeTabsModel.swift DevDeck/AppDelegate.swift DevDeck/Localization/L10n.swift DevDeckTests/SnapshotPolicyTests.swift
git commit -m "feat: capture Claude Code tabs and restore them when Ghostty starts"
```

---

### Task 9: Тумблер в трее и в Settings

**Файлы:**
- Создать: `DevDeck/MenuBar/ClaudeTabsSectionView.swift`
- Правка: `DevDeck/MenuBar/PopoverView.swift:79` (рядом с `ProxySectionView()`)
- Правка: `DevDeck/MainWindow/SettingsView.swift` (рядом с секцией мониторинга, строка 45)
- Правка: `DevDeck/Localization/L10n.swift`

**Интерфейсы:**
- Использует: `ClaudeTabsModel` из окружения, `CommandStore.setClaudeTabsRestore(_:)` (задача 1).
- Отдаёт наружу: `ClaudeTabsSectionView`, строки `L10n.claudeTabsSection`,
  `L10n.claudeTabsRestoreToggle`, `L10n.claudeTabsSnapshotState(_:_:)`,
  `L10n.claudeTabsCaptureNow`, `L10n.claudeTabsRestoreNow`
  (`L10n.claudeTabsRestoreFailed` уже добавлена в задаче 8).

- [ ] **Шаг 1: Добавить строки в `L10n`**

В `DevDeck/Localization/L10n.swift`, в новой секции `// MARK: - Claude tabs`:

```swift
    static var claudeTabsSection: String { t("Claude tabs", "Вкладки Claude") }
    static var claudeTabsRestoreToggle: String {
        t("Restore tabs after a restart", "Восстанавливать вкладки после перезагрузки")
    }
    static var claudeTabsCaptureNow: String { t("Capture now", "Снять снимок") }
    static var claudeTabsRestoreNow: String { t("Restore now", "Восстановить сейчас") }
    static var claudeTabsNoSnapshot: String { t("No snapshot yet", "Снимка пока нет") }
    static func claudeTabsSnapshotState(_ count: Int, _ time: String) -> String {
        t("\(count) tab(s) · \(time)", "вкладок: \(count) · \(time)")
    }
```

- [ ] **Шаг 2: Написать секцию поповера**

`DevDeck/MenuBar/ClaudeTabsSectionView.swift` — по образцу `ProxySectionView`,
свёрнутая по умолчанию:

```swift
import SwiftUI

/// The tray half of the feature: the same toggle as Settings, plus what the snapshot holds.
///
/// The popover is meant to stay minimal, so this is one toggle, one status line and two buttons —
/// the full list lives in the main window.
struct ClaudeTabsSectionView: View {
    @Environment(CommandStore.self) private var store
    @Environment(ClaudeTabsModel.self) private var claudeTabs
    @AppStorage("popover.section.claudeTabs.collapsed") private var collapsed = true

    var body: some View {
        CollapsibleSection(title: L10n.claudeTabsSection,
                           count: claudeTabs.snapshot?.tabs.count ?? 0,
                           runningCount: 0,
                           collapsed: $collapsed) {
            VStack(alignment: .leading, spacing: 6) {
                Toggle(L10n.claudeTabsRestoreToggle, isOn: Binding(
                    get: { store.config.settings.claudeTabsRestore },
                    set: { store.setClaudeTabsRestore($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.small)

                Text(stateText)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    Button(L10n.claudeTabsCaptureNow) { claudeTabs.captureNow() }
                    Button(L10n.claudeTabsRestoreNow) { claudeTabs.restoreNow() }
                        .disabled((claudeTabs.snapshot?.tabs.isEmpty ?? true))
                }
                .buttonStyle(.link)
                .font(.caption)

                if let error = claudeTabs.lastError {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, 4)
        }
    }

    private var stateText: String {
        guard let snapshot = claudeTabs.snapshot, !snapshot.tabs.isEmpty else {
            return L10n.claudeTabsNoSnapshot
        }
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return L10n.claudeTabsSnapshotState(snapshot.tabs.count, formatter.string(from: snapshot.capturedAt))
    }
}
```

`CollapsibleSection` объявлен в `PopoverView.swift:437` и принимает
`title`, `count`, `runningCount`, `collapsed` — здесь `runningCount: 0`, потому что
у снимка нет «работающих» элементов, в отличие от команд и демонов.

- [ ] **Шаг 3: Вставить секцию в поповер**

В `PopoverView.swift` сразу после `ProxySectionView()` (строка 79):

```swift
                    ClaudeTabsSectionView()
```

- [ ] **Шаг 4: Добавить тумблер в Settings**

В `SettingsView.swift`, отдельной секцией рядом с `Section(L10n.memoryMonitoringSection)`:

```swift
            Section(L10n.claudeTabsSection) {
                Toggle(L10n.claudeTabsRestoreToggle, isOn: Binding(
                    get: { store.config.settings.claudeTabsRestore },
                    set: { store.setClaudeTabsRestore($0) }
                ))
            }
```

- [ ] **Шаг 5: Собрать и прогнать весь набор**

Запуск: полная команда тестов.
Ожидание: PASS. Затем — открыть приложение (Cmd-R в Xcode), убедиться, что секция видна
в поповере, тумблер переключается и значение переживает перезапуск приложения.

- [ ] **Шаг 6: Коммит** (только если попросили коммитить)

```bash
git add DevDeck/MenuBar/ClaudeTabsSectionView.swift DevDeck/MenuBar/PopoverView.swift DevDeck/MainWindow/SettingsView.swift DevDeck/Localization/L10n.swift
git commit -m "feat: Claude tabs section in the popover and a toggle in Settings"
```

---

### Task 10: Страница в главном окне и ручная проверка

**Файлы:**
- Создать: `DevDeck/MainWindow/ClaudeTabsView.swift`
- Правка: `DevDeck/AppModel.swift:5` (case в `MainSelection`)
- Правка: `DevDeck/MainWindow/MainWindowView.swift:45,90` (пункт навигации и ветка switch)
- Правка: `CHANGELOG.md`

**Интерфейсы:**
- Использует: `ClaudeTabsModel`, `ClaudeTabEntry`, строки `L10n` из задачи 9.
- Отдаёт наружу: `ClaudeTabsView`, новый case в `MainSelection`.

- [ ] **Шаг 1: Написать страницу**

`DevDeck/MainWindow/ClaudeTabsView.swift`:

```swift
import SwiftUI

/// The full snapshot: which tabs would come back, and which of them we could tie to a session.
/// A row without a session still restores — as a shell in its directory — and saying so here is
/// what keeps that from looking like a bug.
struct ClaudeTabsView: View {
    @Environment(ClaudeTabsModel.self) private var claudeTabs

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Button(L10n.claudeTabsCaptureNow) { claudeTabs.captureNow() }
                Button(L10n.claudeTabsRestoreNow) { claudeTabs.restoreNow() }
                    .disabled(claudeTabs.snapshot?.tabs.isEmpty ?? true)
            }

            if let entries = claudeTabs.snapshot?.tabs, !entries.isEmpty {
                Table(entries) {
                    TableColumn("#") { Text("\($0.order + 1)") }.width(24)
                    TableColumn(L10n.claudeTabsColumnTitle) { Text($0.title) }
                    TableColumn(L10n.claudeTabsColumnDirectory) {
                        Text($0.workingDirectory).foregroundStyle(.secondary)
                    }
                    TableColumn(L10n.claudeTabsColumnSession) { entry in
                        Text(entry.sessionID == nil ? L10n.claudeTabsDirectoryOnly : L10n.claudeTabsSessionFound)
                            .foregroundStyle(entry.sessionID == nil ? .secondary : .primary)
                    }
                }
            } else {
                Text(L10n.claudeTabsNoSnapshot).foregroundStyle(.secondary)
            }
        }
        .padding()
    }
}
```

`ClaudeTabEntry` для `Table` должен быть `Identifiable` — добавить в `Models/ClaudeTabsSnapshot.swift`:

```swift
extension ClaudeTabEntry: Identifiable {
    var id: String { "\(order)-\(workingDirectory)" }
}
```

- [ ] **Шаг 2: Добавить недостающие строки в `L10n`**

```swift
    static var claudeTabsColumnTitle: String { t("Tab", "Вкладка") }
    static var claudeTabsColumnDirectory: String { t("Directory", "Каталог") }
    static var claudeTabsColumnSession: String { t("Session", "Сессия") }
    static var claudeTabsSessionFound: String { t("resumable", "восстановится") }
    static var claudeTabsDirectoryOnly: String { t("directory only", "только каталог") }
```

- [ ] **Шаг 3: Подключить страницу к навигации**

`MainSelection` объявлен не в `MainWindowView`, а в `DevDeck/AppModel.swift:5`. Добавить туда case:

```swift
    case claudeTabs
```

В `DevDeck/MainWindow/MainWindowView.swift:45`, в блоке `pinnedButton`, добавить строку
после `.cleanup`:

```swift
                        pinnedButton(L10n.claudeTabsSection, icon: "macwindow.on.rectangle", selection: .claudeTabs)
```

И в `switch` по выбранному пункту (`MainWindowView.swift:90`), после ветки `case .cleanup`:

```swift
        case .claudeTabs:
            ClaudeTabsView()
```

- [ ] **Шаг 4: Прогнать весь набор тестов**

Запуск: полная команда тестов.
Ожидание: PASS.

- [ ] **Шаг 5: Ручная проверка без перезагрузки**

1. Включить тумблер в поповере. Открыть в Ghostty две-три вкладки с `claude` в разных проектах.
2. Нажать «Снять снимок». Проверить файл:
   `cat ~/Library/Application\ Support/DevDeck/claude-tabs.json` — у вкладок должны быть `sessionID`.
3. Подставить заведомо старое время загрузки, чтобы сымитировать ребут:
   ```bash
   python3 - <<'EOF'
   import json, pathlib
   p = pathlib.Path.home() / "Library/Application Support/DevDeck/claude-tabs.json"
   d = json.loads(p.read_text())
   d["bootTime"] = "2020-01-01T00:00:00Z"
   p.write_text(json.dumps(d))
   EOF
   defaults delete com.proshik.DevDeck claudeTabs.restoredBootTime 2>/dev/null || true
   ```
   (идентификатор бандла взять фактический — из `PRODUCT_BUNDLE_IDENTIFIER`).
4. Полностью закрыть Ghostty и запустить заново. Ожидание: вкладки открылись в своих каталогах,
   в каждой выполнился `claude --resume <id>`, первая вкладка — не пустая.
5. Запустить Ghostty ещё раз, не трогая снимок. Ожидание: **ничего не восстанавливается**,
   в `devdeck.log` строка `ClaudeTabs: not restoring — already restored in this boot`.

- [ ] **Шаг 6: Запись в `CHANGELOG.md`**

Добавить в раздел Unreleased строку о восстановлении вкладок Claude Code после перезагрузки.

- [ ] **Шаг 7: Коммит** (только если попросили коммитить)

```bash
git add DevDeck/MainWindow/ClaudeTabsView.swift DevDeck/MainWindow/MainWindowView.swift DevDeck/AppModel.swift DevDeck/Models/ClaudeTabsSnapshot.swift DevDeck/Localization/L10n.swift CHANGELOG.md
git commit -m "feat: Claude tabs page listing what a restore would reopen"
```

---

### Task 11: Настраиваемый интервал и пропуск неизменившегося набора

**Файлы:**
- Правка: `DevDeck/Models/Config.swift` (`struct Settings`)
- Правка: `DevDeck/ClaudeTabs/ClaudeTabsModel.swift`
- Тест: `DevDeckTests/ClaudeTabsSettingsTests.swift` (дополнить)
- Тест: `DevDeckTests/CaptureSignatureTests.swift` (создать)

**Интерфейсы:**
- Отдаёт наружу: `Settings.claudeTabsCaptureSeconds: Int` (дефолт 15),
  `ClaudeTabsCaptureInterval.clamped(_:) -> TimeInterval`,
  `CaptureOutcome.unchanged`, `ClaudeTabsModel.signature(of:) -> [String]`,
  `ClaudeTabsModel.start(isEnabled:captureInterval:)`.

**Зачем.** Один тик сейчас стоит 0.3 с на перечисление вкладок плюс полное перечитывание
транскриптов, у которых сменился mtime. При четырёх активных сессиях это ~59 МБ **на каждом
тике** — около мегабайта в секунду фонового чтения. Поднимать частоту в лоб нельзя; сначала
надо перестать делать дорогую работу, когда делать нечего.

Заметь: минутное окно — это не окно потери при штатной перезагрузке. `willPowerOffNotification`
и `applicationWillTerminate` снимают снимок сами. Частота важна только для жёстких сценариев:
паника ядра, пропажа питания, принудительный рестарт.

- [ ] **Шаг 1: Поле конфига и зажим границ**

В `struct Settings` — свойство, параметр инициализатора `claudeTabsCaptureSeconds: Int = 15`,
случай в `CodingKeys`, и строка в `init(from:)`:

```swift
        claudeTabsCaptureSeconds = try c.decodeIfPresent(Int.self, forKey: .claudeTabsCaptureSeconds) ?? 15
```

В `ClaudeTabsModel.swift` — чистая функция зажима:

```swift
/// The capture interval, kept inside sane bounds.
///
/// `config.json` is hand-edited and both ends are real hazards: 0 would spin the timer, and a
/// day would leave the feature silently off. Clamping beats rejecting — a nonsense value should
/// still leave a working app.
enum ClaudeTabsCaptureInterval {
    static let minimum = 5
    static let maximum = 300
    static let fallback = 15

    static func clamped(_ seconds: Int) -> TimeInterval {
        TimeInterval(min(max(seconds, minimum), maximum))
    }
}
```

- [ ] **Шаг 2: Подпись набора вкладок и случай `.unchanged`**

`CaptureOutcome` получает `case unchanged`, а `.entries` — вторую составляющую с подписью:

```swift
    case entries([ClaudeTabEntry], signature: [String])
```

Подпись и её использование в `collect`:

```swift
    /// Identity of the open tab set. Two reads with the same signature resolve to the same
    /// entries, so the expensive transcript pass can be skipped outright.
    nonisolated static func signature(of tabs: [GhosttyTab]) -> [String] {
        tabs.map { "\($0.windowID)\t\($0.index)\t\($0.title)\t\($0.workingDirectory)" }
    }
```

В `collect(reader:index:previousSignature:)`, в ветке `.tabs`:

```swift
        case let .tabs(tabs):
            let signature = Self.signature(of: tabs)
            guard signature != previousSignature else { return .unchanged }
            var titles: [String: [TranscriptTitle]] = [:]
            for directory in Set(tabs.map(\.workingDirectory)) {
                titles[directory] = index.titles(forWorkingDirectory: directory)
            }
            return .entries(SessionResolver.resolve(tabs: tabs, titlesByDirectory: titles),
                            signature: signature)
```

В модели — `private var lastSignature: [String]?`. `apply` на `.unchanged` не делает ничего:
ни записи в хранилище, ни присваиваний `@Observable`-полям. На `.entries` подпись сохраняется
после успешной записи. На `.failed` и `.notRunning` — сбрасывается в `nil`, чтобы после сбоя
следующий тик был полноценным, а не считал набор «неизменившимся».

- [ ] **Шаг 3: Таймер, читающий интервал живьём**

`start` принимает второе замыкание, по образцу уже существующего `isEnabled`:

```swift
    func start(isEnabled: @escaping () -> Bool,
               captureInterval: @escaping () -> TimeInterval) {
```

Таймер тикает каждые 5 секунд и почти всегда ничего не делает. Так интервал читается из конфига
на каждом тике — правка `config.json` подхватывается без перезапуска и без пересоздания таймера:

```swift
        // A short fixed tick that mostly does nothing, rather than a timer scheduled at the
        // configured interval: it lets a hand-edited config.json take effect immediately, and a
        // date comparison every 5s costs nothing next to what it guards.
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
```

```swift
    private func tick() async {
        let elapsed = Date().timeIntervalSince(lastCaptureAt ?? .distantPast)
        guard elapsed >= captureInterval() else { return }
        lastCaptureAt = Date()
        await captureIfEnabled()
    }
```

`captureNow()` через `tick` НЕ проходит — явное действие пользователя не throttlится.

В `AppDelegate` — второе замыкание рядом с первым:

```swift
        claudeTabs.start(isEnabled: { [weak store] in store?.config.settings.claudeTabsRestore ?? false },
                         captureInterval: { [weak store] in
                             ClaudeTabsCaptureInterval.clamped(
                                 store?.config.settings.claudeTabsCaptureSeconds
                                     ?? ClaudeTabsCaptureInterval.fallback)
                         })
```

- [ ] **Шаг 4: Тесты**

В `ClaudeTabsSettingsTests` — дефолт 15 при отсутствующем ключе и round-trip.

Новый `DevDeckTests/CaptureSignatureTests.swift`:

```swift
import XCTest
@testable import DevDeck

/// The two-phase capture: an unchanged tab set must cost one AppleScript read and NOTHING else.
/// The counting fake is the point — without it the test would pass against an implementation that
/// re-read every transcript and then threw the result away.
final class CaptureSignatureTests: XCTestCase {

    private final class CountingIndex: TranscriptIndexing, @unchecked Sendable {
        private(set) var calls = 0
        func titles(forWorkingDirectory workingDirectory: String) -> [TranscriptTitle] {
            calls += 1
            return []
        }
    }

    func testClampsBothEnds() {
        XCTAssertEqual(ClaudeTabsCaptureInterval.clamped(0), 5)
        XCTAssertEqual(ClaudeTabsCaptureInterval.clamped(86_400), 300)
        XCTAssertEqual(ClaudeTabsCaptureInterval.clamped(15), 15)
    }

    func testUnchangedTabSetSkipsTheTranscriptPass() {
        let tabs = [GhosttyTab(windowID: "w1", index: 1, title: "✳ a", workingDirectory: "/tmp/a")]
        let index = CountingIndex()
        let signature = ClaudeTabsModel.signature(of: tabs)

        let outcome = ClaudeTabsModel.collect(reader: FakeReader(result: .tabs(tabs)),
                                              index: index,
                                              previousSignature: signature)

        XCTAssertEqual(outcome, .unchanged)
        XCTAssertEqual(index.calls, 0, "an unchanged tab set must not touch the transcripts")
    }

    func testChangedTitleResolvesAgain() {
        let before = [GhosttyTab(windowID: "w1", index: 1, title: "✳ a", workingDirectory: "/tmp/a")]
        let after = [GhosttyTab(windowID: "w1", index: 1, title: "✳ renamed", workingDirectory: "/tmp/a")]
        let index = CountingIndex()

        let outcome = ClaudeTabsModel.collect(reader: FakeReader(result: .tabs(after)),
                                              index: index,
                                              previousSignature: ClaudeTabsModel.signature(of: before))

        guard case .entries = outcome else { return XCTFail("expected a fresh resolve") }
        XCTAssertEqual(index.calls, 1)
    }
}
```

`FakeReader` — переиспользовать существующий фейк `GhosttyTabReading` из `ClaudeTabsModelTests`,
если он там есть; иначе объявить минимальный рядом.

Дополнительно: тест, что `apply(.unchanged)` не переписывает файл снимка (сравнить mtime или
содержимое до и после).

- [ ] **Шаг 5: Прогон и коммит**

Полный набор без `-only-testing`, затем коммит:

```bash
git commit -m "perf: poll Claude tabs more often, but only pay for the reads when they change"
```
