# Движок контейнеров: абстракция, точка в трее, нейминг — план реализации

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** DevDeck определяет активный движок контейнеров (colima или Docker Desktop), показывает в меню-баре зелёную точку, когда он запущен, и называет метрики и кнопки его именем вместо зашитого «colima».

**Architecture:** Протокол `ContainerEngine` с двумя реализациями, которые ходят в файловую систему, список процессов и unix-сокет только через инжектируемые зонды. Чистая функция `EngineSelector.select` выбирает активный движок, `@Observable` `EngineModel` держит результат и пересчитывается двухсекундным таймером трея. Существующие colima-зонды не переписываются, а гейтятся по типу движка через уже существующие замыкания `isVMMonitoringEnabled` / `isClusterHealthEnabled`.

**Tech Stack:** Swift, SwiftUI + AppKit (`NSStatusItem`, `NSRunningApplication`, `NSWorkspace`), Darwin (`kill`, `socket`/`connect`), XCTest.

**Spec:** `docs/superpowers/specs/2026-09-18-container-engine-design.md` — читать вместе с планом, включая раздел «Уточнения при планировании».

## Global Constraints

- Тесты: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'`; префикс `DEVELOPER_DIR` обязателен; один класс — `-only-testing:DevDeckTests/<Class>`.
- Новые `.swift` в `DevDeck/` и `DevDeckTests/` подхватываются автоматически — `project.pbxproj` руками не трогать.
- Probe-паттерн: тесты не запускают процессов, не трогают сеть, реальные пути и реальный список процессов. Всё внешнее — за протоколом с фейком.
- `ContainerEngine.isRunning()` не запускает подпроцессов — вызывается каждые 2 секунды.
- Новое поле конфига декодится с дефолтом (`.auto`), `schemaVersion` не трогать.
- Порядок `DockerHost.allCases` не менять: из индекса выводятся UUID синтетических команд очистки.
- Код и комментарии — по-английски; UI-строки — через `t("en", "ru")` в `L10n`.
- Коммиты: проектный `CLAUDE.md` запрещает коммитить без явной просьбы пользователя. Шаги «Commit» выполнять, только если пользователь разрешил коммиты на время исполнения плана; иначе пропускать и копить изменения в рабочем дереве.

---

## Карта файлов

Создаются:

| Файл | Ответственность |
|---|---|
| `DevDeck/Engine/ContainerEngine.swift` | `ContainerEngineKind`, протокол `ContainerEngine`, протоколы зондов |
| `DevDeck/Engine/EngineProbes.swift` | Живые реализации зондов (`kill`, `FileManager`, `NSRunningApplication`, `connect`) |
| `DevDeck/Engine/ColimaEngine.swift` | colima: установлена / запущена по `ha.pid` |
| `DevDeck/Engine/DockerDesktopEngine.swift` | Docker Desktop: приложение + сокет |
| `DevDeck/Engine/EngineSelector.swift` | Чистая функция выбора активного движка |
| `DevDeck/Engine/EngineModel.swift` | `@Observable` держатель активного движка |
| `DevDeckTests/Support/FakeEngineProbes.swift` | Фейки зондов и `FakeEngine` |
| `DevDeckTests/EngineDetectionTests.swift` | Тесты движков, селектора и модели |
| `DevDeckTests/TrayIconTests.swift` | Тест цвета точки и подписи доступности |

Меняются: `Models/Config.swift`, `Store/CommandStore.swift`, `AppDelegate.swift`, `DevDeckApp.swift`, `MenuBar/TrayIcon.swift`, `MenuBar/MenuBarController.swift`, `MenuBar/HeaderMetric.swift`, `MenuBar/PopoverView.swift`, `MainWindow/SettingsView.swift`, `MainWindow/CleanupView.swift`, `Cleanup/DockerUsage.swift`, `Cleanup/CleanupCommands.swift`, `Cleanup/CleanupModel.swift`, `Diagnostics/EnergyUsage.swift`, `Localization/L10n.swift`, `CLAUDE.md`, и тесты `HeaderMetricTests`, `CleanupCommandsTests`, `CleanupModelTests`, `DockerUsageTests`, `EnergyTallyTests`, `ConfigCodecTests`.

---

### Task 1: Протокол движка, зонды и две реализации

**Files:**
- Create: `DevDeck/Engine/ContainerEngine.swift`
- Create: `DevDeck/Engine/EngineProbes.swift`
- Create: `DevDeck/Engine/ColimaEngine.swift`
- Create: `DevDeck/Engine/DockerDesktopEngine.swift`
- Create: `DevDeckTests/Support/FakeEngineProbes.swift`
- Create: `DevDeckTests/EngineDetectionTests.swift`

**Interfaces:**
- Consumes: ничего.
- Produces:
  - `enum ContainerEngineKind: String, Codable, CaseIterable, Sendable { case colima, dockerDesktop }`
  - `protocol ContainerEngine: Sendable { var kind: ContainerEngineKind { get }; var displayName: String { get }; func isInstalled() -> Bool; func isRunning() -> Bool }`
  - `protocol ProcessLivenessChecking: Sendable { func isAlive(pid: Int32) -> Bool }`
  - `protocol PathProbing: Sendable { func exists(_ path: String) -> Bool; func contents(ofFile path: String) -> String?; func directoryEntries(at path: String) -> [String] }`
  - `protocol AppPresenceProbing: Sendable { func isRunning(bundleID: String) -> Bool; func isInstalled(bundleID: String) -> Bool }`
  - `protocol UnixSocketProbing: Sendable { func canConnect(to path: String) -> Bool }`
  - `struct ColimaEngine: ContainerEngine` — `init(home: String = NSHomeDirectory(), paths: any PathProbing = LivePathProbe(), liveness: any ProcessLivenessChecking = LiveProcessLiveness())`
  - `struct DockerDesktopEngine: ContainerEngine` — `static let bundleID = "com.docker.docker"`, `init(home: String = NSHomeDirectory(), apps: any AppPresenceProbing = LiveAppPresence(), sockets: any UnixSocketProbing = LiveUnixSocketProbe())`
  - Фейки для тестов: `FakePathProbe`, `FakeLiveness`, `FakeAppPresence`, `FakeSocketProbe`, `FakeEngine`

- [ ] **Step 1: Протоколы и тип движка**

`DevDeck/Engine/ContainerEngine.swift`:

```swift
import Foundation

/// The container engines DevDeck knows how to recognise.
enum ContainerEngineKind: String, Codable, CaseIterable, Sendable {
    case colima, dockerDesktop
}

/// A local container engine: its name and whether it is there and up.
///
/// `isRunning()` is polled every 2 s from the tray timer, so implementations must not spawn a
/// process — a file read, a `kill(pid, 0)` or a unix-socket `connect()` at most.
protocol ContainerEngine: Sendable {
    var kind: ContainerEngineKind { get }
    /// As shown in the UI: "colima", "Docker Desktop".
    var displayName: String { get }
    func isInstalled() -> Bool
    func isRunning() -> Bool
}

// MARK: - Probes (behind protocols → engines are tested with fakes, no real paths or processes)

protocol ProcessLivenessChecking: Sendable {
    func isAlive(pid: Int32) -> Bool
}

protocol PathProbing: Sendable {
    func exists(_ path: String) -> Bool
    func contents(ofFile path: String) -> String?
    /// Names (not paths) of the entries of a directory; empty when it doesn't exist.
    func directoryEntries(at path: String) -> [String]
}

protocol AppPresenceProbing: Sendable {
    func isRunning(bundleID: String) -> Bool
    func isInstalled(bundleID: String) -> Bool
}

protocol UnixSocketProbing: Sendable {
    func canConnect(to path: String) -> Bool
}
```

- [ ] **Step 2: Фейки для тестов**

`DevDeckTests/Support/FakeEngineProbes.swift`:

```swift
import Foundation
@testable import DevDeck

final class FakePathProbe: PathProbing, @unchecked Sendable {
    var existing: Set<String> = []
    var files: [String: String] = [:]
    var directories: [String: [String]] = [:]
    func exists(_ path: String) -> Bool { existing.contains(path) || files[path] != nil || directories[path] != nil }
    func contents(ofFile path: String) -> String? { files[path] }
    func directoryEntries(at path: String) -> [String] { directories[path] ?? [] }
}

final class FakeLiveness: ProcessLivenessChecking, @unchecked Sendable {
    var alive: Set<Int32> = []
    func isAlive(pid: Int32) -> Bool { alive.contains(pid) }
}

final class FakeAppPresence: AppPresenceProbing, @unchecked Sendable {
    var running: Set<String> = []
    var installed: Set<String> = []
    func isRunning(bundleID: String) -> Bool { running.contains(bundleID) }
    func isInstalled(bundleID: String) -> Bool { installed.contains(bundleID) }
}

final class FakeSocketProbe: UnixSocketProbing, @unchecked Sendable {
    var connectable: Set<String> = []
    private(set) var attempts: [String] = []
    func canConnect(to path: String) -> Bool { attempts.append(path); return connectable.contains(path) }
}

/// An engine with fixed answers — for the selector and the model.
final class FakeEngine: ContainerEngine, @unchecked Sendable {
    let kind: ContainerEngineKind
    let displayName: String
    var installed: Bool
    var running: Bool
    init(_ kind: ContainerEngineKind, installed: Bool = true, running: Bool = false) {
        self.kind = kind
        self.displayName = kind == .colima ? "colima" : "Docker Desktop"
        self.installed = installed
        self.running = running
    }
    func isInstalled() -> Bool { installed }
    func isRunning() -> Bool { running }
}
```

- [ ] **Step 3: Падающие тесты на оба движка**

`DevDeckTests/EngineDetectionTests.swift`:

```swift
import XCTest
@testable import DevDeck

final class EngineDetectionTests: XCTestCase {
    private let home = "/Users/test"

    // MARK: colima

    private func colima(_ configure: (FakePathProbe, FakeLiveness) -> Void) -> ColimaEngine {
        let paths = FakePathProbe()
        let liveness = FakeLiveness()
        configure(paths, liveness)
        return ColimaEngine(home: home, paths: paths, liveness: liveness)
    }

    func testColimaRunsWhenAnyProfilePidIsAlive() {
        let engine = colima { paths, liveness in
            paths.directories["/Users/test/.colima/_lima"] = ["_config", "colima", "colima-work"]
            paths.files["/Users/test/.colima/_lima/colima/ha.pid"] = "111\n"
            paths.files["/Users/test/.colima/_lima/colima-work/ha.pid"] = "222\n"
            liveness.alive = [222]
        }
        XCTAssertTrue(engine.isRunning())
    }

    func testColimaIsStoppedWhenThePidIsDead() {
        let engine = colima { paths, _ in
            paths.directories["/Users/test/.colima/_lima"] = ["colima"]
            paths.files["/Users/test/.colima/_lima/colima/ha.pid"] = "111"
        }
        XCTAssertFalse(engine.isRunning())
    }

    func testColimaIsStoppedWithoutAPidFileOrWithGarbageInIt() {
        XCTAssertFalse(colima { paths, _ in paths.directories["/Users/test/.colima/_lima"] = ["colima"] }.isRunning())
        XCTAssertFalse(colima { paths, liveness in
            paths.directories["/Users/test/.colima/_lima"] = ["colima"]
            paths.files["/Users/test/.colima/_lima/colima/ha.pid"] = "not-a-pid"
            liveness.alive = [0]
        }.isRunning())
        XCTAssertFalse(colima { _, _ in }.isRunning(), "no ~/.colima at all")
    }

    func testColimaIsInstalledByBinaryOrByItsHomeDirectory() {
        XCTAssertTrue(colima { paths, _ in paths.existing = ["/opt/homebrew/bin/colima"] }.isInstalled())
        XCTAssertTrue(colima { paths, _ in paths.existing = ["/usr/local/bin/colima"] }.isInstalled())
        XCTAssertTrue(colima { paths, _ in paths.existing = ["/Users/test/.colima"] }.isInstalled())
        XCTAssertFalse(colima { _, _ in }.isInstalled())
    }

    func testColimaName() {
        let engine = colima { _, _ in }
        XCTAssertEqual(engine.kind, .colima)
        XCTAssertEqual(engine.displayName, "colima")
    }

    // MARK: Docker Desktop

    private let socket = "/Users/test/.docker/run/docker.sock"

    func testDockerDesktopRunsWhenTheAppIsUpAndTheSocketAnswers() {
        let apps = FakeAppPresence(); apps.running = [DockerDesktopEngine.bundleID]
        let sockets = FakeSocketProbe(); sockets.connectable = [socket]
        XCTAssertTrue(DockerDesktopEngine(home: home, apps: apps, sockets: sockets).isRunning())
    }

    func testDockerDesktopIsStoppedWhenTheSocketIsSilent() {
        let apps = FakeAppPresence(); apps.running = [DockerDesktopEngine.bundleID]
        XCTAssertFalse(DockerDesktopEngine(home: home, apps: apps, sockets: FakeSocketProbe()).isRunning())
    }

    func testDockerDesktopDoesNotTouchTheSocketWhenTheAppIsNotRunning() {
        let sockets = FakeSocketProbe(); sockets.connectable = [socket]
        let engine = DockerDesktopEngine(home: home, apps: FakeAppPresence(), sockets: sockets)
        XCTAssertFalse(engine.isRunning())
        XCTAssertEqual(sockets.attempts, [])
    }

    func testDockerDesktopInstalledAndName() {
        let apps = FakeAppPresence(); apps.installed = [DockerDesktopEngine.bundleID]
        let engine = DockerDesktopEngine(home: home, apps: apps, sockets: FakeSocketProbe())
        XCTAssertTrue(engine.isInstalled())
        XCTAssertFalse(DockerDesktopEngine(home: home, apps: FakeAppPresence(), sockets: FakeSocketProbe()).isInstalled())
        XCTAssertEqual(engine.kind, .dockerDesktop)
        XCTAssertEqual(engine.displayName, "Docker Desktop")
    }
}
```

- [ ] **Step 4: Убедиться, что тесты не компилируются**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/EngineDetectionTests`
Expected: FAIL — `cannot find 'ColimaEngine' in scope`.

- [ ] **Step 5: Живые зонды**

`DevDeck/Engine/EngineProbes.swift`:

```swift
import AppKit
import Darwin

struct LiveProcessLiveness: ProcessLivenessChecking {
    /// `kill(pid, 0)` delivers nothing and only asks whether the pid exists. EPERM means it does
    /// but belongs to another user — still alive.
    func isAlive(pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}

struct LivePathProbe: PathProbing {
    func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func contents(ofFile path: String) -> String? { try? String(contentsOfFile: path, encoding: .utf8) }
    func directoryEntries(at path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
}

struct LiveAppPresence: AppPresenceProbing {
    func isRunning(bundleID: String) -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }
    func isInstalled(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }
}

struct LiveUnixSocketProbe: UnixSocketProbing {
    /// A unix-socket `connect()` answers at once — success, ENOENT or ECONNREFUSED — so this
    /// never blocks. Nothing is written, so SIGPIPE can't happen.
    func canConnect(to path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) }
        }
        return rc == 0
    }
}
```

- [ ] **Step 6: Два движка**

`DevDeck/Engine/ColimaEngine.swift`:

```swift
import Foundation

/// colima is up when a lima host agent is alive: `~/.colima/_lima/<instance>/ha.pid` holds its pid.
/// The `default` profile is the lima instance `colima`, any other profile `colima-<name>`; the
/// directory also holds `_config`/`_networks`, which simply have no `ha.pid`.
struct ColimaEngine: ContainerEngine {
    static let binaryCandidates = ["/opt/homebrew/bin/colima", "/usr/local/bin/colima"]

    let kind = ContainerEngineKind.colima
    let displayName = "colima"

    private let home: String
    private let paths: any PathProbing
    private let liveness: any ProcessLivenessChecking

    init(home: String = NSHomeDirectory(), paths: any PathProbing = LivePathProbe(),
         liveness: any ProcessLivenessChecking = LiveProcessLiveness()) {
        self.home = home
        self.paths = paths
        self.liveness = liveness
    }

    func isInstalled() -> Bool {
        Self.binaryCandidates.contains(where: paths.exists) || paths.exists(home + "/.colima")
    }

    func isRunning() -> Bool {
        let lima = home + "/.colima/_lima"
        return paths.directoryEntries(at: lima).contains { instance in
            guard let text = paths.contents(ofFile: "\(lima)/\(instance)/ha.pid"),
                  let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
            return liveness.isAlive(pid: pid)
        }
    }
}
```

`DevDeck/Engine/DockerDesktopEngine.swift`:

```swift
import Foundation

/// Docker Desktop is up when its app runs and the engine socket accepts a connection.
///
/// The socket stays up while Resource Saver has put the VM to sleep — that still counts as
/// running; waking the VM to find out more is exactly what must not happen. `com.docker.vmnetd`
/// and `com.docker.socket` are launchd daemons that outlive the app, so they are never a signal.
struct DockerDesktopEngine: ContainerEngine {
    static let bundleID = "com.docker.docker"

    let kind = ContainerEngineKind.dockerDesktop
    let displayName = "Docker Desktop"

    private let home: String
    private let apps: any AppPresenceProbing
    private let sockets: any UnixSocketProbing

    init(home: String = NSHomeDirectory(), apps: any AppPresenceProbing = LiveAppPresence(),
         sockets: any UnixSocketProbing = LiveUnixSocketProbe()) {
        self.home = home
        self.apps = apps
        self.sockets = sockets
    }

    func isInstalled() -> Bool { apps.isInstalled(bundleID: Self.bundleID) }

    func isRunning() -> Bool {
        apps.isRunning(bundleID: Self.bundleID) && sockets.canConnect(to: home + "/.docker/run/docker.sock")
    }
}
```

- [ ] **Step 7: Тесты проходят**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/EngineDetectionTests`
Expected: PASS, 9 тестов.

- [ ] **Step 8: Commit** (только с разрешения пользователя — см. Global Constraints)

```bash
git add DevDeck/Engine DevDeckTests/Support/FakeEngineProbes.swift DevDeckTests/EngineDetectionTests.swift
git commit -m "feat(engine): recognise colima and Docker Desktop without spawning processes"
```

---

### Task 2: Настройка движка, селектор и модель

**Files:**
- Modify: `DevDeck/Models/Config.swift` (структура `Settings`: поле, `init`, `CodingKeys`, `init(from:)`)
- Modify: `DevDeck/Store/CommandStore.swift` (рядом с `setClusterHealth`, строка ~257)
- Create: `DevDeck/Engine/EngineSelector.swift`
- Create: `DevDeck/Engine/EngineModel.swift`
- Test: `DevDeckTests/EngineDetectionTests.swift` (дописать), `DevDeckTests/ConfigCodecTests.swift` (дописать)

**Interfaces:**
- Consumes: `ContainerEngine`, `ContainerEngineKind`, `FakeEngine` из Task 1.
- Produces:
  - `enum EnginePreference: String, Codable, CaseIterable, Sendable { case auto, colima, dockerDesktop }` с `var kind: ContainerEngineKind?`
  - `Settings.containerEngine: EnginePreference` (дефолт `.auto`)
  - `CommandStore.setContainerEngine(_ preference: EnginePreference)`
  - `struct EngineChoice { let engine: any ContainerEngine; let running: Bool }`
  - `enum EngineSelector { static func select(_ preference: EnginePreference, from candidates: [any ContainerEngine]) -> EngineChoice? }`
  - `@MainActor @Observable final class EngineModel` — `init(candidates: [any ContainerEngine] = [ColimaEngine(), DockerDesktopEngine()])`, `var preference: () -> EnginePreference`, `private(set) var active: (any ContainerEngine)?`, `private(set) var isActiveRunning: Bool`, `var activeKind: ContainerEngineKind?`, `var activeName: String?`, `func refresh()`

- [ ] **Step 1: Падающие тесты селектора и модели**

Дописать в `DevDeckTests/EngineDetectionTests.swift` (внутрь класса):

```swift
    // MARK: selector

    private func select(_ preference: EnginePreference, _ engines: FakeEngine...) -> EngineChoice? {
        EngineSelector.select(preference, from: engines)
    }

    func testAutoPicksTheRunningEngine() {
        let choice = select(.auto, FakeEngine(.colima), FakeEngine(.dockerDesktop, running: true))
        XCTAssertEqual(choice?.engine.kind, .dockerDesktop)
        XCTAssertEqual(choice?.running, true)
    }

    func testAutoPrefersColimaWhenBothRun() {
        let choice = select(.auto, FakeEngine(.colima, running: true), FakeEngine(.dockerDesktop, running: true))
        XCTAssertEqual(choice?.engine.kind, .colima)
    }

    func testAutoFallsBackToAnInstalledEngineWhenNothingRuns() {
        XCTAssertEqual(select(.auto, FakeEngine(.colima), FakeEngine(.dockerDesktop))?.engine.kind, .colima,
                       "both installed → colima first")
        let onlyDesktop = select(.auto, FakeEngine(.colima, installed: false), FakeEngine(.dockerDesktop))
        XCTAssertEqual(onlyDesktop?.engine.kind, .dockerDesktop)
        XCTAssertEqual(onlyDesktop?.running, false)
    }

    func testAutoFindsNothingWhenNothingIsInstalled() {
        XCTAssertNil(select(.auto, FakeEngine(.colima, installed: false), FakeEngine(.dockerDesktop, installed: false)))
    }

    func testExplicitPreferenceOverridesDetectionEvenWhenNotInstalled() {
        let choice = select(.dockerDesktop, FakeEngine(.colima, running: true),
                            FakeEngine(.dockerDesktop, installed: false))
        XCTAssertEqual(choice?.engine.kind, .dockerDesktop)
        XCTAssertEqual(choice?.running, false)
    }

    // MARK: model

    @MainActor
    func testModelFollowsThePreferenceAndTheRunningState() {
        let colima = FakeEngine(.colima, running: true)
        let desktop = FakeEngine(.dockerDesktop)
        let model = EngineModel(candidates: [colima, desktop])
        var preference = EnginePreference.auto
        model.preference = { preference }

        model.refresh()
        XCTAssertEqual(model.activeKind, .colima)
        XCTAssertEqual(model.activeName, "colima")
        XCTAssertTrue(model.isActiveRunning)

        colima.running = false
        model.refresh()
        XCTAssertEqual(model.activeKind, .colima, "still installed")
        XCTAssertFalse(model.isActiveRunning)

        preference = .dockerDesktop
        model.refresh()
        XCTAssertEqual(model.activeKind, .dockerDesktop)
        XCTAssertEqual(model.activeName, "Docker Desktop")
    }

    @MainActor
    func testModelStartsEmpty() {
        let model = EngineModel(candidates: [FakeEngine(.colima, running: true)])
        XCTAssertNil(model.activeKind, "nothing is known before the first refresh")
        XCTAssertFalse(model.isActiveRunning)
    }
```

Дописать в `DevDeckTests/ConfigCodecTests.swift` (внутрь класса):

```swift
    func testContainerEngineDefaultsToAutoAndRoundTrips() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded.containerEngine, .auto)

        var settings = Settings()
        settings.containerEngine = .dockerDesktop
        let data = try JSONEncoder().encode(settings)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: data).containerEngine, .dockerDesktop)
    }

    func testUnknownContainerEngineValueFallsBackToAuto() throws {
        let decoded = try JSONDecoder().decode(Settings.self, from: Data(#"{"containerEngine":"podman"}"#.utf8))
        XCTAssertEqual(decoded.containerEngine, .auto)
    }
```

- [ ] **Step 2: Убедиться, что тесты не компилируются**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/EngineDetectionTests -only-testing:DevDeckTests/ConfigCodecTests`
Expected: FAIL — `cannot find type 'EnginePreference' in scope`.

- [ ] **Step 3: Поле в конфиге**

В `DevDeck/Models/Config.swift`, над `struct Settings`:

```swift
/// Which container engine DevDeck watches. `auto` picks the running one (see `EngineSelector`).
enum EnginePreference: String, Codable, CaseIterable, Sendable {
    case auto, colima, dockerDesktop

    /// nil for `auto`.
    var kind: ContainerEngineKind? {
        switch self {
        case .auto: return nil
        case .colima: return .colima
        case .dockerDesktop: return .dockerDesktop
        }
    }
}
```

В `Settings` — поле после `activeRemoteProxyID`:

```swift
    /// The container engine to watch; `auto` detects it. A hand-edited unknown value reads as `auto`.
    var containerEngine: EnginePreference
```

В `init(...)` — параметр последним, `containerEngine: EnginePreference = .auto`, и присваивание `self.containerEngine = containerEngine`.
В `CodingKeys` — добавить `containerEngine` в конец списка.
В `init(from:)` — последней строкой:

```swift
        // `try?`: an unknown string (a future engine, a typo) must not fail the whole config.
        containerEngine = (try? c.decodeIfPresent(EnginePreference.self, forKey: .containerEngine)) ?? .auto
```

- [ ] **Step 4: Сеттер в сторе**

В `DevDeck/Store/CommandStore.swift` сразу после `setClusterHealth`:

```swift
    func setContainerEngine(_ preference: EnginePreference) {
        guard config.settings.containerEngine != preference else { return }
        var updated = config
        updated.settings.containerEngine = preference
        persist(updated)
    }
```

- [ ] **Step 5: Селектор**

`DevDeck/Engine/EngineSelector.swift`:

```swift
import Foundation

struct EngineChoice {
    let engine: any ContainerEngine
    let running: Bool
}

/// Which engine DevDeck watches. `candidates` come in priority order — colima first: on the
/// developer's machine it is the main one, and a tie is settled by the setting, not by guessing.
enum EngineSelector {
    static func select(_ preference: EnginePreference, from candidates: [any ContainerEngine]) -> EngineChoice? {
        if let wanted = preference.kind {
            // An explicit choice is final, installed or not — then it simply isn't running.
            guard let engine = candidates.first(where: { $0.kind == wanted }) else { return nil }
            return EngineChoice(engine: engine, running: engine.isRunning())
        }
        if let engine = candidates.first(where: { $0.isRunning() }) {
            return EngineChoice(engine: engine, running: true)
        }
        if let engine = candidates.first(where: { $0.isInstalled() }) {
            return EngineChoice(engine: engine, running: false)
        }
        return nil
    }
}
```

- [ ] **Step 6: Модель**

`DevDeck/Engine/EngineModel.swift`:

```swift
import Foundation
import Observation

/// The engine DevDeck is watching right now, for the tray dot, the labels and the probe gates.
/// Refreshed by the tray's 2 s timer; the preference is read live, so a config edit (UI or by
/// hand) takes effect on the next tick without a separate hook.
@MainActor
@Observable
final class EngineModel {
    private(set) var active: (any ContainerEngine)?
    private(set) var isActiveRunning = false

    var activeKind: ContainerEngineKind? { active?.kind }
    var activeName: String? { active?.displayName }

    @ObservationIgnored var preference: () -> EnginePreference = { .auto }
    @ObservationIgnored private let candidates: [any ContainerEngine]

    init(candidates: [any ContainerEngine] = [ColimaEngine(), DockerDesktopEngine()]) {
        self.candidates = candidates
    }

    func refresh() {
        let choice = EngineSelector.select(preference(), from: candidates)
        // Assign only on change: every write notifies the popover, and this runs every 2 s.
        if choice?.engine.kind != active?.kind { active = choice?.engine }
        let running = choice?.running ?? false
        if running != isActiveRunning { isActiveRunning = running }
    }
}
```

- [ ] **Step 7: Тесты проходят**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/EngineDetectionTests -only-testing:DevDeckTests/ConfigCodecTests`
Expected: PASS.

- [ ] **Step 8: Commit** (только с разрешения пользователя)

```bash
git add DevDeck/Engine DevDeck/Models/Config.swift DevDeck/Store/CommandStore.swift DevDeckTests
git commit -m "feat(engine): engine preference in config and active-engine selection"
```

---

### Task 3: Точка в трее

**Files:**
- Modify: `DevDeck/MenuBar/TrayIcon.swift`
- Modify: `DevDeck/MenuBar/MenuBarController.swift`
- Modify: `DevDeck/AppDelegate.swift`
- Modify: `DevDeck/DevDeckApp.swift:13-19`
- Modify: `DevDeck/Localization/L10n.swift`
- Create: `DevDeckTests/TrayIconTests.swift`

**Interfaces:**
- Consumes: `EngineModel` (`refresh()`, `activeName`, `isActiveRunning`), `CommandStore.config.settings.containerEngine`.
- Produces:
  - `TrayIcon.engineBadgeColor(running: Bool) -> NSColor?`
  - `L10n.trayAccessibility(engineName: String?, running: Bool) -> String`
  - `AppDelegate.engine: EngineModel`, в окружении попапа и главного окна — `.environment(engine)`
  - `MenuBarController.init(..., engine: EngineModel)`

- [ ] **Step 1: Падающий тест**

`DevDeckTests/TrayIconTests.swift`:

```swift
import XCTest
@testable import DevDeck

final class TrayIconTests: XCTestCase {
    func testEngineBadgeIsGreenOnlyWhileTheEngineRuns() {
        XCTAssertEqual(TrayIcon.engineBadgeColor(running: true), .systemGreen)
        XCTAssertNil(TrayIcon.engineBadgeColor(running: false))
    }

    func testAccessibilityNamesTheEngineAndItsState() {
        XCTAssertEqual(L10n.trayAccessibility(engineName: nil, running: false), "DevDeck")
        XCTAssertTrue(L10n.trayAccessibility(engineName: "colima", running: true).contains("colima"))
        XCTAssertNotEqual(L10n.trayAccessibility(engineName: "colima", running: true),
                          L10n.trayAccessibility(engineName: "colima", running: false))
    }
}
```

- [ ] **Step 2: Убедиться, что тест падает**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/TrayIconTests`
Expected: FAIL — `type 'TrayIcon' has no member 'engineBadgeColor'`.

- [ ] **Step 3: Цвет и подпись**

В `DevDeck/MenuBar/TrayIcon.swift`, после `badgeColor(for:)`:

```swift
    /// Colour of the bottom-left engine dot; nil (no dot) while the engine is stopped or unknown.
    static func engineBadgeColor(running: Bool) -> NSColor? {
        running ? .systemGreen : nil
    }
```

В `DevDeck/Localization/L10n.swift`, рядом с прочими строками меню-бара (или в конце файла, в новой `// MARK: - Tray`):

```swift
    // MARK: - Tray

    static func trayAccessibility(engineName: String?, running: Bool) -> String {
        guard let engineName else { return "DevDeck" }
        return running
            ? t("DevDeck — \(engineName) is running", "DevDeck — \(engineName) запущена")
            : t("DevDeck — \(engineName) is stopped", "DevDeck — \(engineName) остановлена")
    }
```

- [ ] **Step 4: Тест проходит**

Run: та же команда, что в Step 2.
Expected: PASS.

- [ ] **Step 5: Модель в AppDelegate и окружении**

В `DevDeck/AppDelegate.swift` — свойство рядом с `let energy = EnergyModel()`:

```swift
    let engine = EngineModel()
```

В `applicationDidFinishLaunching`, сразу после `store.start()` и строки лога запуска — до того, как кто-либо спросит о движке:

```swift
        // The engine is known before the first probe asks for it; the tray timer keeps it fresh.
        engine.preference = { [weak store] in store?.config.settings.containerEngine ?? .auto }
        engine.refresh()
```

Вызов `MenuBarController(...)` получает последний аргумент `engine: engine`.

В `DevDeck/DevDeckApp.swift` после `.environment(appDelegate.claudeTabs)` (строка 19):

```swift
                .environment(appDelegate.engine)
```

- [ ] **Step 6: Точка в MenuBarController**

В `DevDeck/MenuBar/MenuBarController.swift`:

1. Поле `private let engine: EngineModel` рядом с `manager`.
2. Второй бейдж рядом с `badgeView`:

```swift
    /// Green dot bottom-left while the container engine runs — the counterpart of the pressure dot.
    private let engineBadgeView: NSView = {
        let dot: CGFloat = 6
        let view = NSView(frame: NSRect(x: 0, y: 0, width: dot, height: dot))
        view.wantsLayer = true
        view.layer?.cornerRadius = dot / 2
        view.isHidden = true
        return view
    }()
```

3. `init` получает параметр `engine: EngineModel` последним, присваивает `self.engine = engine` до `super.init()`, добавляет `.environment(engine)` в цепочку `PopoverView()` после `.environment(energy)`.
4. В блоке `if let button = statusItem.button` после активации констрейнтов `badgeView`:

```swift
            engineBadgeView.translatesAutoresizingMaskIntoConstraints = false
            button.addSubview(engineBadgeView)
            NSLayoutConstraint.activate([
                engineBadgeView.widthAnchor.constraint(equalToConstant: d),
                engineBadgeView.heightAnchor.constraint(equalToConstant: d),
                engineBadgeView.leadingAnchor.constraint(equalTo: button.centerXAnchor, constant: -half),
                engineBadgeView.bottomAnchor.constraint(equalTo: button.centerYAnchor, constant: half),
            ])
```

5. В теле таймера, после блока с `badgeView`:

```swift
                self.engine.refresh()
                if let color = TrayIcon.engineBadgeColor(running: self.engine.isActiveRunning) {
                    self.engineBadgeView.layer?.backgroundColor = color.cgColor
                    self.engineBadgeView.isHidden = false
                } else {
                    self.engineBadgeView.isHidden = true
                }
                self.statusItem.button?.image?.accessibilityDescription =
                    L10n.trayAccessibility(engineName: self.engine.activeName, running: self.engine.isActiveRunning)
```

Точка появляется с первым тиком таймера, то есть через ≤2 с после запуска приложения, — это нормально, отдельный прогон при старте не нужен.

- [ ] **Step 7: Сборка и ручная проверка**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild build -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

Ручная проверка (запустить собранное приложение): при запущенной colima через ≤2 с в левом нижнем углу глифа появляется зелёная точка; `colima stop` — точка пропадает в течение 2 с; `colima start` — появляется. Бейдж давления в правом верхнем углу работает как раньше.

- [ ] **Step 8: Commit** (только с разрешения пользователя)

```bash
git add DevDeck/MenuBar DevDeck/AppDelegate.swift DevDeck/DevDeckApp.swift DevDeck/Localization/L10n.swift DevDeckTests/TrayIconTests.swift
git commit -m "feat(tray): green dot while the container engine runs"
```

---

### Task 4: Метрики — имя движка, гейт colima-зондов, скрытие недоступных ячеек

**Files:**
- Modify: `DevDeck/MenuBar/HeaderMetric.swift`
- Modify: `DevDeck/MenuBar/PopoverView.swift` (строки ~7-11, 151-172, 226, 266, 317-319)
- Modify: `DevDeck/MainWindow/SettingsView.swift:6-8, 68-72`
- Modify: `DevDeck/Diagnostics/EnergyUsage.swift:121-128`
- Modify: `DevDeck/AppDelegate.swift:34-37`
- Test: `DevDeckTests/HeaderMetricTests.swift`, `DevDeckTests/EnergyTallyTests.swift:54,74`

**Interfaces:**
- Consumes: `EngineModel.activeKind`, `EngineModel.activeName` (Task 2), `.environment(engine)` (Task 3).
- Produces:
  - `HeaderMetric.vmEngine` (вместо `.vmColima`)
  - `HeaderMetric.title(engineName: String?) -> String`
  - `HeaderMetric.isAvailable(engineKind: ContainerEngineKind?) -> Bool`
  - `EnergyTally.vmName = "VM"` — имя строки VM в списке энергопотребителей

- [ ] **Step 1: Падающие тесты**

В `DevDeckTests/HeaderMetricTests.swift`:
- в `testEveryMetricHasATitleAndADistinctExplanation` заменить `metric.title.isEmpty` на `metric.title(engineName: "colima").isEmpty`;
- в `testEveryGridMetricIsEitherPinnedOrHiddenExactlyOnce` заменить `.vmColima` на `.vmEngine`;
- дописать:

```swift
    func testVMTitleCarriesTheEngineName() {
        XCTAssertEqual(HeaderMetric.vmEngine.title(engineName: "colima"), "VM colima")
        XCTAssertEqual(HeaderMetric.vmEngine.title(engineName: "Docker Desktop"), "VM Docker Desktop")
        XCTAssertEqual(HeaderMetric.vmEngine.title(engineName: nil), "VM")
        XCTAssertEqual(HeaderMetric.cpuLoad.title(engineName: "colima"), HeaderMetric.cpuLoad.title(engineName: nil),
                       "only the VM cell depends on the engine")
    }

    func testColimaProbedMetricsAreHiddenForOtherEngines() {
        for metric in [HeaderMetric.vmEngine, .diskVM, .cluster] {
            XCTAssertTrue(metric.isAvailable(engineKind: .colima), "\(metric)")
            XCTAssertFalse(metric.isAvailable(engineKind: .dockerDesktop), "\(metric)")
            XCTAssertFalse(metric.isAvailable(engineKind: nil), "\(metric)")
        }
        for metric in [HeaderMetric.memory, .swap, .vmMinikube, .pressure, .swapRate, .cpuLoad, .battery] {
            XCTAssertTrue(metric.isAvailable(engineKind: .dockerDesktop), "\(metric)")
            XCTAssertTrue(metric.isAvailable(engineKind: nil), "\(metric)")
        }
    }
```

В `DevDeckTests/EnergyTallyTests.swift` строки 54 и 74: `"VM colima"` → `"VM"`.

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/HeaderMetricTests -only-testing:DevDeckTests/EnergyTallyTests`
Expected: FAIL — `type 'HeaderMetric' has no member 'vmEngine'`.

- [ ] **Step 3: HeaderMetric**

В `DevDeck/MenuBar/HeaderMetric.swift`:
- в `case memory, swap, cluster, vmColima, ...` заменить `vmColima` на `vmEngine`;
- заменить `var title: String { switch self { ... } }` на:

```swift
    /// The VM cell is named after the engine it measures ("VM colima", "VM Docker Desktop");
    /// plain "VM" when no engine is known.
    func title(engineName: String?) -> String {
        switch self {
        case .memory: return L10n.memory
        case .swap: return L10n.swap
        case .cluster: return L10n.cluster
        case .vmEngine: return engineName.map { "VM \($0)" } ?? "VM"
        case .vmMinikube: return "VM minikube"
        case .pressure: return L10n.pressure
        case .diskVM: return L10n.diskVM
        case .swapRate: return L10n.swapRate
        case .cpuLoad: return L10n.cpuLoad
        case .battery: return L10n.battery
        }
    }

    /// The VM memory, VM disk and cluster cells come from colima-only probes (`colima ssh`,
    /// `colima list`). Under any other engine — or none — they have nothing to say and are hidden
    /// rather than left blank.
    func isAvailable(engineKind: ContainerEngineKind?) -> Bool {
        switch self {
        case .vmEngine, .diskVM, .cluster: return engineKind == .colima
        default: return true
        }
    }
```

- в `static let pinned` заменить `.vmColima` на `.vmEngine`.

В `DevDeck/Localization/L10n.swift` в `metricHelp(_:)` переименовать `case .vmColima:` в `case .vmEngine:` (текст не меняется — см. «Уточнения при планировании» в спеке).

- [ ] **Step 4: Имя VM в списке энергопотребителей**

В `DevDeck/Diagnostics/EnergyUsage.swift` в `struct EnergyTally`, над `displayName(path:)`:

```swift
    /// Row name of the Virtualization.framework VM. Rendered as "VM <engine>" by the popover:
    /// which engine owns the VM process can't be told from the path, the active engine can.
    static let vmName = "VM"
```

В доккомментарии `displayName(path:)` строку про `"VM colima"` заменить на `→ `vmName`` и в теле `return "VM colima"` → `return vmName`.

- [ ] **Step 5: Попап и настройки** (без них основной таргет не соберётся — тесты гонять после этого шага)

В `DevDeck/MenuBar/PopoverView.swift`:

1. После `@Environment(EnergyModel.self) private var energy` добавить `@Environment(EngineModel.self) private var engine`.
2. Пиннед-сетка:

```swift
                    ForEach(HeaderMetric.pinned.filter { $0.isAvailable(engineKind: engine.activeKind) },
                            id: \.self) { metric in
```

3. Скрытая сетка — к существующему фильтру батареи добавить доступность:

```swift
                        ForEach(HeaderMetric.hidden.filter {
                                    ($0 != .battery || energy.battery != nil) && $0.isAvailable(engineKind: engine.activeKind)
                                }, id: \.self) { metric in
```

4. `explainedMetric.title + ": "` → `explainedMetric.title(engineName: engine.activeName) + ": "`.
5. В `cellValue` — `case .vmColima:` → `case .vmEngine:`.
6. В `metricCell(_:_:color:)` — `Text(metric.title)` → `Text(metric.title(engineName: engine.activeName))`.
7. В `energyConsumers` — `Text(consumer.name)` →

```swift
                        Text(consumer.name == EnergyTally.vmName
                             ? HeaderMetric.vmEngine.title(engineName: engine.activeName)
                             : consumer.name)
```

В `DevDeck/MainWindow/SettingsView.swift`: добавить `@Environment(EngineModel.self) private var engine` после `@Environment(ProxyManager.self) private var proxy`; в списке метрик `Text(metric.title)` → `Text(metric.title(engineName: engine.activeName))`.

Проверить, что не осталось старых обращений:

Run: `grep -rn "\.title\b" DevDeck --include=*.swift | grep -i metric; grep -rn "vmColima" DevDeck DevDeckTests`
Expected: пусто.

- [ ] **Step 6: Гейт colima-зондов**

В `DevDeck/AppDelegate.swift` заменить две строки (~34 и ~37):

```swift
        // The VM memory/disk and cluster probes speak `colima ssh`/`colima list`: under another
        // engine they stay off (caches cleared) instead of reporting a stopped colima.
        manager.isVMMonitoringEnabled = { [weak store, weak engine] in
            (store?.config.settings.vmMemoryMonitoring ?? false) && engine?.activeKind == .colima
        }
        manager.isClusterHealthEnabled = { [weak store, weak engine] in
            (store?.config.settings.clusterHealthMonitoring ?? false) && engine?.activeKind == .colima
        }
```

`isMinikubeMonitoringEnabled` и `isHostMonitoringEnabled` не трогать: `minikube ssh` и метрики хоста от движка не зависят.

- [ ] **Step 7: Тесты проходят, ручная проверка**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/HeaderMetricTests -only-testing:DevDeckTests/EnergyTallyTests -only-testing:DevDeckTests/ProcessManagerVMSamplerTests`
Expected: PASS.

Ручная проверка на этой машине: в попапе ячейка называется «VM colima», значения как раньше. Затем в `config.json` выставить `"containerEngine": "dockerDesktop"` — в течение 2 с ячейки «VM …», «Диск VM» и «Кластер» исчезают, точка в трее гаснет (Docker Desktop не установлен); вернуть `"auto"` — всё возвращается.

- [ ] **Step 8: Commit** (только с разрешения пользователя)

```bash
git add DevDeck DevDeckTests
git commit -m "feat(metrics): name the VM after the active engine, hide colima-only cells elsewhere"
```

---

### Task 5: Очистка — `DockerHost.engineVM`, имя движка в названиях и кнопке перезапуска

**Files:**
- Modify: `DevDeck/Cleanup/DockerUsage.swift:5-10, 221-229`
- Modify: `DevDeck/Cleanup/CleanupCommands.swift:26-65`
- Modify: `DevDeck/Cleanup/CleanupModel.swift`
- Modify: `DevDeck/MainWindow/CleanupView.swift`
- Modify: `DevDeck/Localization/L10n.swift:214-305`
- Modify: `DevDeck/AppDelegate.swift`
- Test: `DevDeckTests/CleanupCommandsTests.swift`, `DevDeckTests/CleanupModelTests.swift`, `DevDeckTests/DockerUsageTests.swift:149`

**Interfaces:**
- Consumes: `EngineModel.activeKind`, `EngineModel.activeName`, `HeaderMetric.vmEngine.title(engineName:)` (Task 4).
- Produces:
  - `DockerHost.engineVM` (вместо `.colima`, первый в `allCases`)
  - `L10n.dockerHostLabel(_ host: DockerHost, engineName: String?) -> String`
  - `CleanupCommands.command(_ action: CleanupAction, on host: DockerHost, engineName: String?) -> Command`
  - `CleanupCommands.restartEngine(engineName: String) -> Command`, `CleanupCommands.restartEngineID`
  - `CleanupModel.engineKind: () -> ContainerEngineKind?`, `CleanupModel.engineName: () -> String?`, `CleanupModel.visibleHosts: [DockerHost]`, `CleanupModel.restartEngine()`

- [ ] **Step 1: Падающие тесты**

В `DevDeckTests/CleanupCommandsTests.swift`:
- все `on: .colima` → `on: .engineVM, engineName: "colima"`; все `on: .minikube` → `on: .minikube, engineName: "colima"`; в цикле `CleanupCommands.command(.deadContainers, on: host)` → `CleanupCommands.command(.deadContainers, on: host, engineName: "colima")`, аналогично в `testIDsAreStableAndDistinct`;
- `CleanupCommands.restartColima` → `CleanupCommands.restartEngine(engineName: "colima")` во всех местах;
- переименовать `testColimaCommandsRunInsideTheVMThroughSh` в `testEngineVMCommandsRunInsideColimaThroughSh`, `testRestartColimaBringsMinikubeBack` — в `testRestartEngineBringsMinikubeBack`;
- дописать:

```swift
    /// The ids are what ties a cleanup's run state and log across re-creations. They derive from
    /// the position in `DockerHost.allCases`, so renaming a case is fine and reordering is not.
    func testIDsArePinned() {
        let expected: [(CleanupAction, DockerHost, String)] = [
            (.deadContainers, .engineVM, "C1EA0000-0000-4000-8000-000000000011"),
            (.buildCache, .engineVM, "C1EA0000-0000-4000-8000-000000000012"),
            (.unusedImages, .engineVM, "C1EA0000-0000-4000-8000-000000000013"),
            (.deadContainers, .minikube, "C1EA0000-0000-4000-8000-000000000021"),
            (.buildCache, .minikube, "C1EA0000-0000-4000-8000-000000000022"),
            (.unusedImages, .minikube, "C1EA0000-0000-4000-8000-000000000023"),
        ]
        for (action, host, uuid) in expected {
            XCTAssertEqual(CleanupCommands.id(action, on: host).uuidString, uuid, "\(action) on \(host)")
        }
        XCTAssertEqual(CleanupCommands.restartEngineID.uuidString, "C1EA0000-0000-4000-8000-0000000000FF")
    }

    func testCommandNamesShowTheEngineNotTheCaseName() {
        let name = CleanupCommands.command(.buildCache, on: .engineVM, engineName: "Docker Desktop").name
        XCTAssertTrue(name.contains("Docker Desktop"), name)
        XCTAssertFalse(name.contains("engineVM"), name)
        XCTAssertTrue(CleanupCommands.command(.buildCache, on: .minikube, engineName: "colima").name.contains("minikube"))
        XCTAssertTrue(CleanupCommands.restartEngine(engineName: "colima").name.contains("colima"))
    }
```

В `DevDeckTests/CleanupModelTests.swift`: `.colima` → `.engineVM`; `model.restartColima()` → `model.restartEngine()`; `CleanupCommands.restartColima.id` → `CleanupCommands.restartEngineID`. Дописать:

```swift
    @MainActor
    func testEngineVMBoxIsShownOnlyUnderColima() {
        let model = CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()),
                                 probe: FakeDockerUsageProbe([:]))
        model.engineKind = { .colima }
        XCTAssertEqual(model.visibleHosts, [.engineVM, .minikube])
        model.engineKind = { .dockerDesktop }
        XCTAssertEqual(model.visibleHosts, [.minikube])
        model.engineKind = { nil }
        XCTAssertEqual(model.visibleHosts, [.minikube])
    }

    @MainActor
    func testRefreshSkipsTheEngineVMOutsideColima() async {
        let probe = FakeDockerUsageProbe([.engineVM: DockerUsage(), .minikube: DockerUsage()])
        let model = CleanupModel(manager: ProcessManager(runner: FakeCommandRunner()), probe: probe)
        model.engineKind = { .dockerDesktop }
        await model.refresh()
        XCTAssertNil(model.usage[.engineVM], "colima ssh must not run under Docker Desktop")
        XCTAssertNotNil(model.usage[.minikube])
    }
```

Прежде чем писать эти два теста, открыть начало `CleanupModelTests.swift` и сверить, как там уже создаются `CleanupModel`, `ProcessManager` и `FakeCommandRunner`, — использовать ту же форму (если у `FakeCommandRunner` другой инициализатор или в файле есть хелпер — взять его).

В `DevDeckTests/DockerUsageTests.swift:149`: `LiveDockerUsageProbe.invocation(.colima)` → `LiveDockerUsageProbe.invocation(.engineVM)`.

- [ ] **Step 2: Убедиться, что тесты падают**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/CleanupCommandsTests -only-testing:DevDeckTests/CleanupModelTests -only-testing:DevDeckTests/DockerUsageTests`
Expected: FAIL — `type 'DockerHost' has no member 'engineVM'`.

- [ ] **Step 3: Переименование case**

`DevDeck/Cleanup/DockerUsage.swift`, строки 5-10:

```swift
/// Which docker daemon a figure or a cleanup refers to: the container engine's own (the VM's
/// daemon), or the one inside the minikube node container — where `minikube docker-env` builds
/// and the cluster's images live, all of it inside the single `minikube` volume on the VM's disk.
///
/// Order matters: `CleanupCommands.id(_:on:)` derives ids from the position in `allCases`.
enum DockerHost: String, CaseIterable, Hashable, Sendable {
    case engineVM, minikube
}
```

В `invocation(_:)` (строка ~227): `case .colima:` → `case .engineVM:` и комментарий над функцией дополнить строкой `/// engineVM is reached through colima only for now — Docker Desktop is the next spec's job.`

В `CleanupCommands.swift`, в `extension DockerHost` `wrap(_:)`: `case .colima:` → `case .engineVM:`, в доккомментарии «this daemon's VM. colima (lima)» оставить, добавив ту же строку про colima-only.

- [ ] **Step 4: Строки**

В `DevDeck/Localization/L10n.swift`:

```swift
    /// How a docker host is named in the UI: the engine's own daemon by the engine's name.
    static func dockerHostLabel(_ host: DockerHost, engineName: String?) -> String {
        switch host {
        case .engineVM: return engineName ?? "VM"
        case .minikube: return "minikube"
        }
    }
```

Заменить сигнатуры и тела (по одной, `grep -n` по имени, чтобы найти):

```swift
    static func cleanupIntro(engineName: String?) -> String {
        let name = engineName ?? "VM"
        return t("Where the \(name) disk goes and what can be freed. Named volumes (databases, module caches) and running containers are never touched.",
                 "Куда уходит диск \(name) и что можно освободить. Именованные volumes (базы, кэши модулей) и работающие контейнеры не трогаются.")
    }
    static func dockerHostTitle(_ host: DockerHost, engineName: String?) -> String {
        switch host {
        case .engineVM:
            let name = dockerHostLabel(host, engineName: engineName)
            return t("\(name) — the docker VM", "\(name) — docker в VM")
        case .minikube: return t("minikube — inside the cluster node", "minikube — внутри ноды кластера")
        }
    }
    static func dockerHostNote(_ host: DockerHost, engineName: String?) -> String? {
        switch host {
        case .engineVM: return nil
        case .minikube:
            let name = engineName ?? "VM"
            return t("All of it sits inside that one minikube volume on the \(name) disk — freeing anything here frees the \(name) disk too.",
                     "Всё это лежит внутри того самого тома minikube на диске \(name) — освобождая здесь, вы освобождаете и диск \(name).")
        }
    }
    static func cleanupConfirmTitle(_ action: CleanupAction, _ host: DockerHost, engineName: String?) -> String {
        let name = dockerHostLabel(host, engineName: engineName)
        return t("Free “\(cleanupActionTitle(action))” in \(name)?",
                 "Освободить «\(cleanupActionTitle(action))» в \(name)?")
    }
    static func restartEngine(_ name: String) -> String { t("Restart \(name)", "Перезапустить \(name)") }
    static func restartEngineConfirmTitle(_ name: String) -> String { t("Restart \(name)?", "Перезапустить \(name)?") }
    static func cleanupCommandName(_ action: CleanupAction, _ host: DockerHost, engineName: String?) -> String {
        let name = dockerHostLabel(host, engineName: engineName)
        return t("Cleanup: \(cleanupActionTitle(action).lowercased()) (\(name))",
                 "Очистка: \(cleanupActionTitle(action).lowercased()) (\(name))")
    }
```

Удалить `restartColima` и `restartColimaConfirmTitle`. `restartColimaConfirmMessage` и `restartColimaConfirmButton` переименовать в `restartEngineConfirmMessage` / `restartEngineConfirmButton` (тексты не меняются — в них нет имени colima). `cleanupMemoryNote` не трогать (фактура lima — второй кусок).

- [ ] **Step 5: Команды**

`DevDeck/Cleanup/CleanupCommands.swift`, `enum CleanupCommands`:

```swift
    static func command(_ action: CleanupAction, on host: DockerHost, engineName: String?) -> Command {
        Command(id: id(action, on: host),
                name: L10n.cleanupCommandName(action, host, engineName: engineName),
                command: host.wrap(action.script))
    }

    /// `colima restart` alone leaves the cluster down: the minikube node container has restart
    /// policy `no`, so it is started again explicitly. colima only for now — the caller shows the
    /// button only under colima.
    static func restartEngine(engineName: String) -> Command {
        Command(id: restartEngineID, name: L10n.restartEngine(engineName), command: "colima restart && minikube start")
    }

    static let restartEngineID = UUID(uuidString: "C1EA0000-0000-4000-8000-0000000000FF")!
```

В `allIDs` — `restartColimaID` → `restartEngineID`.

- [ ] **Step 6: Модель очистки**

`DevDeck/Cleanup/CleanupModel.swift`:

1. Поля после `lastRunID`:

```swift
    /// Injected by `AppDelegate`; the defaults keep a bare model (tests) on colima.
    @ObservationIgnored var engineKind: () -> ContainerEngineKind? = { .colima }
    @ObservationIgnored var engineName: () -> String? = { "colima" }

    /// The engine's own daemon is reached through `colima ssh` — under any other engine its box
    /// and its probe are skipped. minikube is reached through `minikube ssh` and always shown.
    var visibleHosts: [DockerHost] {
        DockerHost.allCases.filter { $0 != .engineVM || engineKind() == .colima }
    }
```

2. В `refresh()` — перед `Task.detached` взять `let hosts = visibleHosts` и в цикле `for host in hosts` вместо `DockerHost.allCases`.
3. `run(_:on:)` — `CleanupCommands.command(action, on: host, engineName: engineName())`.
4. `restartColima()` →

```swift
    func restartEngine() {
        start(CleanupCommands.restartEngine(engineName: engineName() ?? "colima"))
    }
```

5. `restartState` — `CleanupCommands.restartColimaID` → `CleanupCommands.restartEngineID`.

В `DevDeck/AppDelegate.swift`, в `applicationDidFinishLaunching` сразу после `engine.refresh()` из Task 3:

```swift
        cleanupModel.engineKind = { [weak engine] in engine?.activeKind }
        cleanupModel.engineName = { [weak engine] in engine?.activeName }
```

- [ ] **Step 7: Страница очистки**

`DevDeck/MainWindow/CleanupView.swift`:

1. `@Environment(EngineModel.self) private var engine` после `manager`.
2. `ForEach(DockerHost.allCases, id: \.self) { hostBox($0) }` → `ForEach(model.visibleHosts, id: \.self) { hostBox($0) }`.
3. `memoryBox` показывать только под colima: в `body` заменить `memoryBox` на `if engine.activeKind == .colima { memoryBox }`.
4. `L10n.cleanupIntro` → `L10n.cleanupIntro(engineName: engine.activeName)`; `L10n.dockerHostTitle(host)` → `L10n.dockerHostTitle(host, engineName: engine.activeName)`; `L10n.dockerHostNote(host)` → `L10n.dockerHostNote(host, engineName: engine.activeName)`.
5. В `memoryBox`: `Text("VM colima")` → `Text(HeaderMetric.vmEngine.title(engineName: engine.activeName))`; `Button(L10n.restartColima)` → `Button(L10n.restartEngine(engine.activeName ?? "colima"))`.
6. В трёх `switch` по `Pending` (строки ~227-249): `L10n.restartColimaConfirmTitle` → `L10n.restartEngineConfirmTitle(engine.activeName ?? "colima")`, `restartColimaConfirmMessage` → `restartEngineConfirmMessage`, `restartColimaConfirmButton` → `restartEngineConfirmButton`, `model.restartColima()` → `model.restartEngine()`; а где для `.action` вызывается `L10n.cleanupConfirmTitle(a, h)` — добавить `engineName: engine.activeName`.

Проверить, что старых имён не осталось:

Run: `grep -rn "restartColima\|on: \.colima\|invocation(\.colima)\|\[\.colima" DevDeck DevDeckTests`
Expected: пусто. (Голый `.colima` в `ContainerEngineKind`/`EnginePreference` законен, поэтому шаблон ищет только формы, относящиеся к `DockerHost`. Дополнительно просмотреть `grep -rn "case \.colima" DevDeck` — каждое совпадение должно быть в `switch` по движку или настройке, а не по `DockerHost`.)

- [ ] **Step 8: Тесты проходят**

Run: та же команда, что в Step 2.
Expected: PASS.

- [ ] **Step 9: Commit** (только с разрешения пользователя)

```bash
git add DevDeck DevDeckTests
git commit -m "feat(cleanup): engine-neutral docker host, engine name in cleanup and restart"
```

---

### Task 6: Выбор движка в настройках, подписи тумблеров, документация, полный прогон

**Files:**
- Modify: `DevDeck/MainWindow/SettingsView.swift:50-62`
- Modify: `DevDeck/Localization/L10n.swift:310-312, 483-486`
- Modify: `CLAUDE.md` (раздел «Project structure»)

**Interfaces:**
- Consumes: `CommandStore.setContainerEngine(_:)`, `EnginePreference` (Task 2), `EngineModel.activeName` (Task 2), `.environment(engine)` в SettingsView (Task 4).
- Produces: ничего нового для других задач.

- [ ] **Step 1: Строки**

В `DevDeck/Localization/L10n.swift`:

```swift
    static func vmMonitoringToggle(engineName: String?) -> String {
        let name = engineName ?? "VM"
        return t("Show VM memory (\(name)) and per-run peak", "Показывать память VM (\(name)) и пик за прогон")
    }
    static func clusterHealthToggle(engineName: String?) -> String {
        let name = engineName ?? "VM"
        return t("Cluster health (\(name) + minikube status in the deck)",
                 "Здоровье кластера (статус \(name) + minikube в деке)")
    }
    static var containerEnginePicker: String { t("Container engine", "Движок контейнеров") }
    static func containerEngineOption(_ preference: EnginePreference) -> String {
        switch preference {
        case .auto: return t("Detect automatically", "Определять автоматически")
        case .colima: return "colima"
        case .dockerDesktop: return "Docker Desktop"
        }
    }
```

Старые `static var vmMonitoringToggle` и `static var clusterHealthToggle` удалить.

- [ ] **Step 2: Настройки**

В `DevDeck/MainWindow/SettingsView.swift`, в секции мониторинга, **перед** тумблером `vmMonitoringToggle`:

```swift
                Picker(L10n.containerEnginePicker, selection: Binding(
                    get: { store.config.settings.containerEngine },
                    set: { store.setContainerEngine($0) }
                )) {
                    ForEach(EnginePreference.allCases, id: \.self) { preference in
                        Text(L10n.containerEngineOption(preference)).tag(preference)
                    }
                }
```

Вызовы `L10n.vmMonitoringToggle` и `L10n.clusterHealthToggle` → `L10n.vmMonitoringToggle(engineName: engine.activeName)` и `L10n.clusterHealthToggle(engineName: engine.activeName)`.

- [ ] **Step 3: CLAUDE.md**

В блоке «Project structure» после строки `│   ├── Diagnostics/ ...` добавить:

```
│   ├── Engine/          # ContainerEngine (colima / Docker Desktop): installed/running without
│   │                    # spawning processes, EngineSelector, EngineModel — tray dot, VM labels,
│   │                    # gates for the colima-only probes
```

- [ ] **Step 4: Полный прогон**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'`
Expected: `** TEST SUCCEEDED **`, ни одного падения. Если что-то упало — разобрать, не маскируя.

- [ ] **Step 5: Ручная проверка целиком**

На этой машине (colima, Docker Desktop не установлен):
1. Трей: зелёная точка слева снизу при запущенной colima, гаснет после `colima stop` в течение 2 с, возвращается после `colima start`.
2. Попап: «VM colima», «Диск VM», «Кластер» — со значениями как до изменений; в списке энергопотребителей строка VM называется «VM colima».
3. Настройки: пикер «Движок контейнеров», по умолчанию «Определять автоматически»; тумблеры говорят «(colima)».
4. Очистка: блок «colima — docker в VM», блок minikube, кнопка «Перезапустить colima»; название запущенной очистки в логах — «Очистка: … (colima)».
5. Пикер → «Docker Desktop»: точка гаснет, ячейки VM/диск/кластер исчезают, на странице очистки остаётся только блок minikube, блока памяти нет, тумблеры говорят «(Docker Desktop)». Пикер → «Определять автоматически»: всё возвращается.

Результат проверки показать пользователю до любых следующих шагов (MR и прочее — только по его подтверждению).

- [ ] **Step 6: Commit** (только с разрешения пользователя)

```bash
git add DevDeck CLAUDE.md
git commit -m "feat(settings): choose the container engine; engine name in monitoring toggles"
```
