# DevDeck — Proxy Manager (раздача + обнаружение + маршрутизация)

> Статус: **план, к реализации**. Реализацию делать в этом репозитории. Без явной просьбы **не коммитить** (см. `CLAUDE.md`).

## Контекст (зачем это)

У пользователя два Mac в одной Wi-Fi. На **личном** есть VPN (из РФ → заграничный VPN), на **рабочем** — нет, и на рабочем нужно запускать **Claude Code** (и, возможно, другие CLI) через этот VPN.

Рабочая ручная схема сегодня: на личном `gost -L :9999` (auto HTTP+SOCKS прокси, слушает `0.0.0.0`, выходит через full-tunnel VPN); на рабочем `export HTTPS_PROXY=http://<ip-личного>:9999 && claude`.

Что бесит в ручной схеме и почему это встраиваем в DevDeck:
- IP личного мака постоянно меняется (переподключение Wi-Fi, хотспот) → **надоело копировать IP** → нужно авто-обнаружение в LAN.
- `gost` при ручном запуске падал → **нужна супервизия/авто-рестарт**.
- Через VPN должен идти **только запущенный инструмент**, а рабочий VPN и остальная система — не затрагиваться → **инъекция env в конкретный процесс, а не системный прокси**.

DevDeck — нативное menu-bar приложение (Swift + SwiftUI/AppKit, sandbox-free, macOS 15+, без сторонних зависимостей), которое уже умеет запускать и **супервизировать демоны** (watchdog/рестарт, конфликт портов, «усыновление» выживших). Runnable-сущности уже моделируются как `Command` с полем `env:[String:String]`. Поэтому фича **переиспользует движок демонов** для запуска `gost` и **`Command.env`** для инъекции `HTTPS_PROXY`. Реально новое — только **Bonjour (обнаружение/анонс)** и небольшой **`ProxyManager`**.

Одно и то же приложение работает на обоих маках; пользователь просто использует нужную сторону:
- **Share** (личный): супервизируемый демон `gost` + анонс в LAN по Bonjour.
- **Use** (рабочий): обнаружение анонсированных прокси, выбор «активного», запуск команд с флагом `routeThroughProxy` с наложенным env прокси.

## Зафиксированные решения

1. **Движок = управлять `gost`** (Homebrew, `/opt/homebrew/bin/gost`, v3.2.6) как супервизируемым демоном сейчас. Записать «опционально написать свой Swift/Network.framework прокси позже» как **future work** в `docs/PLAN.md`.
2. **Обнаружение = Bonjour/mDNS** через `Network.framework` `NWBrowser`, тип сервиса `_devdeck-proxy._tcp`; анонсируется работающий порт `gost` + TXT-запись. (На сетях с изоляцией клиентов не работает — это приемлемо, т.к. там и сам прокси не пробивается.)
3. **Безопасность = опциональный пароль.** По умолчанию открытый; можно включить `user:pass`. Клиент подставляет креды автоматически. В TXT анонсируется только `auth=1`, пароль — никогда. Пароль хранится в **Keychain**, не в `config.json`.
4. **Маршрутизация на клиенте = «активный прокси» + флаг у команды.** Пользователь выбирает найденный прокси активным (сохраняется по имени Bonjour → переподхватывается в следующей сессии). У команд появляется `routeThroughProxy: Bool`; при запуске, если активный прокси разрешился, накладываются `HTTPS_PROXY`/`HTTP_PROXY` (+ lowercase/`ALL_PROXY`/`NO_PROXY`). Если флаг стоит, но активного прокси нет → **явная ошибка**, никогда не запускать без прокси молча.

## Архитектура

- Плагинов нет: фичи — это `@MainActor @Observable` синглтоны, собираемые в `AppDelegate` и прокидываемые через `.environment(...)`. Добавляем синглтон **`ProxyManager`**, повторяя обвязку `ProcessManager` (`AppDelegate.swift:16,27–35`).
- Новые подсистемы следуют **probe-паттерну** (`protocol X: Sendable` + `LiveX` + `FakeX`, инъекция), как в `Diagnostics/ClusterHealth.swift` / `Process/PortInspector.swift`.
- Запуск/супервизия `gost` **переиспользует существующий движок демонов без изменений**: `ProcessManager.run` → watchdog (по `watchdogEnabled`), `adoptSurvivingDaemons` (матчит осиротевшие по строке команды), предпроверка/панель конфликта портов.
- Наложение env работает единообразно для zsh/sudo/terminal, т.к. все раннеры читают `command.env` — наложение в единственной точке `startRun` покрывает всех.
- Новые `.swift` файлы подхватываются автоматически (Xcode `PBXFileSystemSynchronizedRootGroup`) → **правки `.pbxproj` не нужны**. `Info.plist` подключён через build setting → его правка тоже не требует правки `.pbxproj`.

## Изменения модели данных

**Новая модель `DevDeck/Models/ProxyShare.swift`** (хост-сторона, персистится; пароль — в Keychain, не здесь):

```swift
struct ProxyShare: Codable, Equatable {
    var port: Int = 9999
    var authEnabled: Bool = false
    var username: String = ""
    var serviceName: String = ""            // анонсируемое имя Bonjour; по умолчанию = имя хоста
    // устойчивый init(from:) с decodeIfPresent ?? default (как Command/Settings)

    static let daemonID = UUID(uuidString: "6057D9E0-0000-4000-8000-000000000001")!  // стабильный ключ супервизии + adopt
    static let gostCandidates = ["/opt/homebrew/bin/gost", "/usr/local/bin/gost"]
    var gostPath: String? { Self.gostCandidates.first { FileManager.default.fileExists(atPath: $0) } }

    /// gost v3 auto (http+socks) listener; авторизация опциональна. Синтаксис проверен.
    ///   open: gost -L 'auto://:9999'   |   auth: gost -L 'auto://user:pass@:9999'
    func toCommand(gostPath: String, password: String?) -> Command {
        let creds = (authEnabled && !username.isEmpty) ? "\(username):\(password ?? "")@" : ""
        let listener = "auto://\(creds):\(port)"
        return Command(id: Self.daemonID, name: L10n.proxyShareDaemonName,   // лог использует NAME → пароль не логируется
                       command: "\(gostPath) -L '\(listener)'",
                       isDaemon: true, watchdogEnabled: true, port: port)    // watchdog = тот самый авто-рестарт
    }
}
```

Поток в супервизию: `ProxyManager` достаёт пароль из Keychain, строит этот `Command`, вызывает `processManager.adoptSurvivingDaemons(commands:[daemonID: cmd])`, затем `processManager.run(cmd)`, если ещё не запущен. **Нового кода супервизии — ноль.**

**Эфемерный `DiscoveredProxy`** (клиент-сторона, НЕ персистится; в `DevDeck/Proxy/ProxyDiscovery.swift`): `name` (идентичность Bonjour), `host`, `port`, `authRequired`, `exitIP?`, `proto`, `schema`.

**`Command`** (`Models/Command.swift`): добавить `routeThroughProxy: Bool = false` в memberwise-init, `CodingKeys` и `init(from:)` (`decodeIfPresent ?? false`).

**`Settings`** (`Models/Config.swift`), всё `decodeIfPresent ?? default`: `proxyShareEnabled: Bool=false`, `proxyDiscoveryEnabled: Bool=false`, `activeProxyName: String?=nil`, `activeProxyUsername: String?=nil`.

**`Config`** (`Models/Config.swift`): добавить `proxy: ProxyShare` (`?? ProxyShare()`); поднять `currentSchemaVersion 1→2` (старые файлы всё равно грузятся через устойчивый декод; обновить `DefaultConfigTests`/`ConfigCodecTests`).

## Новые подсистемы (probe-паттерн) — `DevDeck/Proxy/`

**`ProxyDiscovering`** (`ProxyDiscovery.swift`): `func results() -> AsyncStream<[DiscoveredProxy]>` + `stop()`. `LiveProxyDiscovery` = `NWBrowser(for: .bonjourWithTXTRecord(type:"_devdeck-proxy._tcp", domain:nil), using:.tcp)`, маппит `browseResultsChangedHandler` → полный набор. **Push-based (без polling-цикла).** В MVP host/port берутся **из TXT-записи** (обе стороны наши) → per-result резолвинг через `NWConnection` не нужен.

**`ProxyAdvertising`** (`ProxyAdvertiser.swift`): `advertise(_:)`, `updateTXT(_:)`, `stop()`. Использовать **`NetService` только для публикации** (НЕ `NWListener`, который забиндил бы свой сокет) — анонсируем порт, который уже держит `gost`. `LiveProxyAdvertiser` — `@MainActor`. **TXT (schema v1):** `v=1`, `proto=http+socks`, `auth=1|0`, `host=<LAN IPv4>`, `port=<порт gost>`, `vpnip=<exit IP>` (опустить, если неизвестен). Ключа с паролем нет никогда (проверяется тестом). **Выбор LAN IP обязан брать `en*` и исключать `utun*`/`lo0`** (у Share-мака есть VPN-туннель — см. Риски). **Exit IP** получаем best-effort вне main через `ProcessTree.run("/usr/bin/curl", ["-s","--max-time","5","-x","http://[user:pass@]127.0.0.1:<port>","https://api.ipify.org"])` → `updateTXT(vpnip:)` (доказывает, что выход реально через VPN).

**Фейки** (`DevDeckTests/Support/`): `FakeProxyDiscovering` (continuation + `emit([...])`), `FakeProxyAdvertising` (пишет `advertised`, `lastTXT`, `stopCount`), `FakeProxyCredentialStore` (in-memory).

## ProxyManager + точка инъекции env

**`DevDeck/Proxy/ProxyManager.swift`** — `@MainActor @Observable final class`, прокидывается через `.environment`. Инъекция зависимостей (probe-паттерн): `discovering`, `advertising`, `credentials` (Keychain), плюс `weak var store: CommandStore?`, `weak var processManager: ProcessManager?`. Observable-состояние: `discovered: [DiscoveredProxy]`, вычисляемое `activeProxy` (`discovered.first { $0.name == settings.activeProxyName }`), `advertising`, `gostMissing`, `lastExitIP`.

Жизненный цикл (`start()` из `AppDelegate` после того, как store/manager созданы):
1. **Share:** если `proxyShareEnabled` → резолв `gostPath` (иначе `gostMissing=true`, стоп), собрать cmd (пароль из Keychain), `adoptSurvivingDaemons`, затем `run`, если idle.
2. **Анонс завязан на состояние демона:** наблюдать `processManager.states[ProxyShare.daemonID]` (через `withObservationTracking`, пере-armed с `[weak self]`, или уже существующие нотификации `.daemonStarted/.daemonStopped`). На `.daemonRunning` → `advertise(...)` + запустить curl за exit-IP; при выходе → `stop()`. Рестарты watchdog заново триггерят анонс автоматически.
3. **Обнаружение:** если `proxyDiscoveryEnabled` → `Task { for await set in discovering.results() { self.discovered = set } }` (один push-цикл).

**Хук env (суть) — НЕ импортировать ProxyManager в ProcessManager.** Добавить замыкание на `ProcessManager`, прокинуть в `AppDelegate` ровно как `isClusterHealthEnabled`:

```swift
// AppDelegate
manager.proxyRouting = { [weak proxyManager] cmd in proxyManager?.routing(for: cmd) ?? .notRouted }
```

`ProxyManager.routing(for:)` → `.unavailable` (нет активного прокси, или нужна авторизация, но нет кредов) | `.routed(env:)` | `.notRouted`. Чистый билдер env в `DevDeck/Proxy/ProxyRouting.swift`:

```swift
func proxyEnv(host: String, port: Int, user: String?, pass: String?) -> [String:String] {
    let auth = user.map { "\($0):\(pass ?? "")@" } ?? ""
    let url = "http://\(auth)\(host):\(port)"
    return ["HTTPS_PROXY":url,"HTTP_PROXY":url,"ALL_PROXY":url,
            "https_proxy":url,"http_proxy":url,"all_proxy":url,          // многие CLI читают только lowercase
            "NO_PROXY":"localhost,127.0.0.1,::1","no_proxy":"localhost,127.0.0.1,::1"]
}
```

**Точка наложения** = начало `ProcessManager.startRun` (единственная точка `runner.start`), под условием `command.routeThroughProxy`: `.unavailable` → лог `L10n.proxyUnavailable`, `states[id]=.failed(code: proxyUnavailableCode)`, `post .proxyUnavailable(name:)`, `return`; `.routed(env)` → `effective.env.merge(env){ _,new in new }`, затем `runner.start(effective)`.

## Keychain — `DevDeck/Proxy/ProxyCredentialStore.swift`

`protocol ProxyCredentialStore: Sendable { password(for:) ; setPassword(_:for:) }` + `KeychainProxyCredentialStore` (`SecItemCopyMatching` / upsert через delete-then-add, service `"DevDeck.proxy"`). Ключи аккаунта: хост `"proxy-share:<daemonID>"`, клиент `"proxy-client:<bonjourName>"`. Юзернеймы — в конфиге (`ProxyShare.username` / `Settings.activeProxyUsername`); пароли — только в Keychain.

## UI

- **Поповер** (`MenuBar/PopoverView.swift` + новый `MenuBar/ProxySectionView.swift`): блок хоста (строка демона gost переиспользует `states[daemonID]` для статус-точки, play/stop, бейдж «advertising» `wifi` + exit IP; `PortConflictPanel` работает автоматически); блок клиента (`CollapsibleSection` из `discovered`, `lock.fill` при `authRequired`, exit IP, радио-выбор активного; заголовок показывает имя активного или `proxyNone`). Новый `@AppStorage` для сворачивания.
- **Главное окно** (`MainWindow/MainWindowView.swift`, `AppModel.swift`): в `MainSelection` добавить `case proxy`; закреплённая кнопка «Proxy» (символ `network`) рядом с Settings; новый **`MainWindow/ProxyShareEditorView.swift`** (grouped Form): секция Share (toggle включения, порт, toggle auth, username `TextField` + `SecureField`→Keychain, serviceName, статус gost/работает/exit, предупреждение `gostNotFound` по образцу `ghosttyNotFound`, подпись про изоляцию сети); секция Discovery (toggle включения, список найденных + выбор активного, username+`SecureField`, когда активному прокси нужна авторизация).
- **Редактор команды** (`MainWindow/CommandEditorView.swift`): `Toggle(L10n.routeThroughProxyToggle, isOn: $draft.routeThroughProxy)` + подпись с именем активного прокси или предупреждением «нет активного прокси». Сохранение через существующий `assembledDraft`/`upsert`.
- **Настройки** (`MainWindow/SettingsView.swift`): `Section(L10n.proxySection)` с двумя toggle-включениями (по образцу memory-тумблеров), через новые мутаторы `CommandStore`.
- **L10n** (`Localization/L10n.swift`, EN/RU): `proxy`, `proxySection`, `proxyShareDaemonName`, `proxyShareToggle`, `proxyDiscoveryToggle`, `routeThroughProxyToggle`, `proxyActive`, `proxyNone`, `proxyAuthRequired`, `proxyExitIP`, `proxyAdvertising`, `gostNotFound`, `proxyUnavailable`, `proxyPassword`, `proxyPortHint`, `proxyIsolatedNetworkHint`.

## Обработка ошибок / краёв

- **gost не установлен** → `gostMissing=true`, предупреждение в редакторе, не стартовать (по образцу отсутствия Ghostty).
- **Флаг стоит, но нет активного прокси / нет кредов** → `.unavailable` → явная ошибка + нотификация; никогда без прокси.
- **Конфликт порта** → переиспользуется как есть (у синтетической команды есть `port`).
- **Анонс/снятие анонса** управляются состоянием демона (push); переживают рестарты watchdog.
- **Разрешение Local Network в macOS 15** → добавить ключи в `Info.plist`, иначе NWBrowser молча ничего не возвращает.

## Риски (из реального кода)

1. **Приватность Local Network в macOS 15 (главный):** обязательно добавить `NSLocalNetworkUsageDescription` + `NSBonjourServices` (`_devdeck-proxy._tcp`) в `Info.plist`, иначе обнаружение/анонс молча не работают. Готового Bonjour-кода для примера в репо нет.
2. **Утечка VPN-интерфейса:** выбор LAN-IP в анонсере обязан исключать `utun*`/`lo0` и брать `en*`, иначе анонсируется адрес туннеля и клиенты не подключатся. Самое тонкое место по корректности.
3. **Пароль в `ps`/argv:** `auto://user:pass@:port` светит пароль в `ps`; он не попадает в `config.json` (Keychain) и в логи (лог использует `command.name`). Режим gost с конфиг-файлом — отложенный фикс.
4. **Adopt при рестарте со сменённым паролем:** осиротевший gost не совпадёт по строке команды → всплывёт как обычный конфликт порта (существующий UX kill&start). Приемлемо.
5. **Обход в terminal-цепочке:** `runChainInTerminal` вызывает `runner.start` напрямую, минуя `startRun` → наложение прокси не применится к «вся-цепочка-в-одной-вкладке». Одиночные terminal-команды и по-шаговые цепочки — покрыты. Отложено + отмечено.
6. **Бамп схемы до 2** трогает `DefaultConfigTests`/`ConfigCodecTests` — обновить вместе.

## MVP vs отложенное (YAGNI)

**MVP:** всё выше — ProxyShare + устойчивый конфиг; Keychain (Live+Fake); Share через существующий движок демонов (adopt+run+watchdog) с обработкой отсутствия gost; NetService-анонс + TXT + best-effort exit IP, завязанный на состояние демона; NWBrowser-обнаружение → список в поповере; наложение `routeThroughProxy` в `startRun` с явной ошибкой `.unavailable`; toggle-включения в Settings, редактор, секция поповера, флаг у команды, L10n; ключи `Info.plist`; тесты; заметка в PLAN.md.

**Отложено (явно):** свой Swift-прокси (заметка future work); резолвинг эндпоинта через NWConnection (пока host/port несёт TXT); прокси-env для «вся-цепочка-в-одной-вкладке-терминала»; режим gost с конфиг-файлом (спрятать пароль из `ps`); несколько одновременных Share; мульти-интерфейсный/peer-анонс; SOCKS-only/PAC; динамическое определение изоляции сети; ACL/ротация кредов на клиента.

## Пофайлово

**Создать:** `Models/ProxyShare.swift`; `Proxy/ProxyManager.swift`, `Proxy/ProxyDiscovery.swift`, `Proxy/ProxyAdvertiser.swift`, `Proxy/ProxyRouting.swift`, `Proxy/ProxyCredentialStore.swift`; `MainWindow/ProxyShareEditorView.swift`; `MenuBar/ProxySectionView.swift`; тесты `DevDeckTests/Support/FakeProxy{Discovering,Advertising,CredentialStore}.swift` + `DevDeckTests/{ProxyShareMapping,ProxyRouting,ProxyManagerDiscovery,ProxyManagerRoutingResolution,ProxyManagerShare,ProcessManagerProxy,ProxyCredentialStore,ProxyConfigCodec}Tests.swift`.

**Изменить:** `Models/Command.swift` (+`routeThroughProxy`); `Models/Config.swift` (Settings +4, Config +`proxy`, schema→2); `Store/CommandStore.swift` (+`setProxyShareEnabled`/`setProxyDiscoveryEnabled`/`setActiveProxy`/`upsertProxyShare`); `Process/ProcessManager.swift` (+замыкание `proxyRouting`, `proxyUnavailableCode`, наложение в `startRun`); `Diagnostics/Notifier.swift` + `LiveNotifier.swift` (+`proxyUnavailable`); `AppDelegate.swift` (собрать+прокинуть+`start` `proxyManager`, передать в `MenuBarController`); `DevDeckApp.swift` + `MenuBar/MenuBarController.swift` (`.environment(proxyManager)`); `MenuBar/PopoverView.swift`; `AppModel.swift` (`MainSelection.proxy`); `MainWindow/{MainWindowView,CommandEditorView,SettingsView}.swift`; `Localization/L10n.swift`; `Info.plist` (ключи Bonjour); `docs/PLAN.md` (секция Proxy Manager + заметка future work про свой прокси).

## Проверка

1. **Юнит-тесты (`just test`), без реальной сети/процессов:** `ProxyShare.toCommand` open vs auth argv + `daemonID`; `proxyEnv` (с/без `user:pass`, upper+lower+ALL+NO_PROXY); обновление списка обнаружения + резолв активного по имени (в т.ч. активный удалён → nil); резолв маршрутизации (нет активного / auth-без-кредов → `.unavailable`; активный+креды → `.routed`); инъекция env в `ProcessManager` (у запущенной routed-команды `env` содержит прокси-переменные через `FakeCommandRunner`; `.unavailable` → `.failed`, раннер НЕ стартует, нотификация отправлена); анонс на `.daemonRunning` (TXT `auth` отражает Share, **без ключа пароля**), снятие анонса на stop; round-trip Keychain + удаление; v1-JSON без прокси декодится в дефолты + schema 2.
2. **End-to-end (два мака или мак + хотспот iPhone):** личный мак: включить Share, Start → демон gost «работает», поповер показывает advertising + exit IP (должен быть выход VPN, напр. `78.40.193.132`). Рабочий мак: включить Discovery → прокси появляется по имени (без ввода IP); сделать активным; у команды `claude` поставить флаг `routeThroughProxy`; Run → убедиться, что запускается с `HTTPS_PROXY` и трафик идёт через VPN (`curl -x http://<host>:<port> https://api.ipify.org` возвращает exit IP VPN). Убить gost → watchdog перезапускает, анонс возобновляется. Включить auth → клиент спрашивает пароль (Keychain), routed-запуск по-прежнему работает.
3. **Ручная проверка:** `just run`; убедиться, что запрос разрешения Local Network появляется один раз; при выключенном Discovery нет активности NWBrowser; команды без флага по-прежнему запускаются без прокси.

**Не коммитить** без явной просьбы (по `CLAUDE.md` DevDeck).
