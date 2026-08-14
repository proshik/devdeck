# Popover Metrics (VM disk, live pressure, swap threshold) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Добавить в панель попапа ячейку «Диск VM» с уведомлением о заполнении, оживить «Давление»/«Скорость свопа» вне сборок, красить «Своп» по порогу, убрать «Компрессор».

**Architecture:** Новый проб `VMDiskProbing` (`colima ssh -- df -Pk`) по образцу `ClusterHealthProbing`; кеши и refresh-методы в `ProcessManager` по образцу `refreshClusterHealth`/`refreshVMSample`; UI — правки ячеек в `PopoverView.memoryHeader`. Спека: `docs/superpowers/specs/2026-08-14-popover-metrics-design.md`.

**Tech Stack:** Swift / SwiftUI, XCTest. Проект на `PBXFileSystemSynchronizedRootGroup` — новые файлы в `DevDeck/` и `DevDeckTests/` подхватываются без правки pbxproj.

## Global Constraints

- НЕ коммитить: конвенция проекта — коммит только по явной просьбе пользователя. Вместо commit-шагов — финальное предложение коммита.
- Сборка/тесты только с `DEVELOPER_DIR=/Applications/Xcode.app` (xcode-select смотрит в CommandLineTools).
- Тесты: фейковые пробы, никаких реальных процессов/ssh (конвенция `DevDeckTests`).
- Все user-facing строки — через `L10n.t(en, ru)`.
- Комментарии в коде — на английском (как в существующих файлах Diagnostics/).

Прогон тестов (после каждой задачи — целевой класс, в конце — весь набор):

```bash
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj \
  -scheme DevDeck -destination 'platform=macOS' -quiet \
  -only-testing:DevDeckTests/<ClassName> 2>&1 | tail -20
```

---

### Task 1: VMDisk.swift — типы и парсер df

**Files:**
- Create: `DevDeck/Diagnostics/VMDisk.swift`
- Test: `DevDeckTests/VMDiskTests.swift`

**Interfaces:**
- Produces: `struct VMDiskInfo: Equatable { let usedBytes: UInt64; let totalBytes: UInt64 }` c `fraction: Double`, `format() -> String`; `func parseDF(_ output: String) -> VMDiskInfo?`; `protocol VMDiskProbing: Sendable { func sample() -> VMDiskInfo? }`; `struct LiveVMDiskProbe: VMDiskProbing`.

- [ ] **Step 1: Write the failing test**

```swift
import XCTest
@testable import DevDeck

final class VMDiskTests: XCTestCase {

    // Real `df -Pk /var/lib/docker` output from the colima VM.
    private let sample = """
    Filesystem     1024-blocks     Used Available Capacity Mounted on
    /dev/vdb1        102087160 41940044  55372340      44% /var/lib/docker
    """

    func testParseDF() throws {
        let info = try XCTUnwrap(parseDF(sample))
        XCTAssertEqual(info.totalBytes, 102_087_160 * 1024)
        XCTAssertEqual(info.usedBytes, 41_940_044 * 1024)
    }

    func testParseDFRejectsGarbage() {
        XCTAssertNil(parseDF(""))
        XCTAssertNil(parseDF("no such file or directory"))
        XCTAssertNil(parseDF("Filesystem 1024-blocks Used\n/dev/vdb1 abc def"))
        // Zero total must not produce a division-by-zero cell.
        XCTAssertNil(parseDF("Filesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vdb1 0 0 0 0% /x"))
    }

    func testFractionAndFormat() {
        let gib: UInt64 = 1_073_741_824
        let info = VMDiskInfo(usedBytes: 40 * gib, totalBytes: 97 * gib)
        XCTAssertEqual(info.fraction, 40.0 / 97.0, accuracy: 0.001)
        XCTAssertEqual(info.format(), "40 / 97 GB · 41%")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `cannot find 'parseDF' in scope`, `cannot find type 'VMDiskInfo'`.

- [ ] **Step 3: Write minimal implementation**

```swift
import Foundation

// MARK: - VMDiskInfo

/// Disk usage of the docker filesystem inside the colima VM. Binary GiB, like the other metrics.
struct VMDiskInfo: Equatable {
    let usedBytes: UInt64
    let totalBytes: UInt64

    var fraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    /// "40 / 97 GB · 41%" — whole GiB (disk sizes don't need decimals).
    func format() -> String {
        let gib = 1_073_741_824.0
        let percent = totalBytes > 0 ? Int((fraction * 100).rounded()) : 0
        return String(format: "%.0f / %.0f GB · %d%%",
                      Double(usedBytes) / gib, Double(totalBytes) / gib, percent)
    }
}

/// Parse `df -Pk <path>` output (POSIX format, 1024-byte blocks): second line,
/// columns 2 (total) and 3 (used). nil on malformed output or zero total.
func parseDF(_ output: String) -> VMDiskInfo? {
    let lines = output.split(whereSeparator: \.isNewline)
    guard lines.count >= 2 else { return nil }
    let cols = lines[1].split(separator: " ", omittingEmptySubsequences: true)
    guard cols.count >= 3,
          let totalK = UInt64(cols[1]), totalK > 0,
          let usedK = UInt64(cols[2]) else { return nil }
    return VMDiskInfo(usedBytes: usedK * 1024, totalBytes: totalK * 1024)
}

// MARK: - Probe

/// Behind a protocol → ProcessManager/popover are tested with a fake (no ssh spawns).
protocol VMDiskProbing: Sendable {
    func sample() -> VMDiskInfo?
}

/// The real probe: `colima ssh -- df -Pk /var/lib/docker`. Blocking (~200-300 ms) → call off-main.
struct LiveVMDiskProbe: VMDiskProbing {
    func sample() -> VMDiskInfo? {
        let out = ProcessTree.run("/opt/homebrew/bin/colima", ["ssh", "--", "df", "-Pk", "/var/lib/docker"])
            ?? ProcessTree.run("/usr/bin/env", ["colima", "ssh", "--", "df", "-Pk", "/var/lib/docker"])
        return out.flatMap(parseDF)
    }
}
```

- [ ] **Step 4: Run test to verify it passes** (`-only-testing:DevDeckTests/VMDiskTests`)

---

### Task 2: ProcessManager — cachedVMDisk + refreshVMDisk

**Files:**
- Create: `DevDeckTests/Support/FakeVMDiskProbe.swift`
- Modify: `DevDeck/Process/ProcessManager.swift` (поля ~строка 179, init ~строки 181–199, метод рядом с `refreshClusterHealth` ~строка 858)
- Test: `DevDeckTests/VMDiskTests.swift` (дописать класс `ProcessManagerDiskTests`)

**Interfaces:**
- Consumes: `VMDiskInfo`, `VMDiskProbing` из Task 1.
- Produces: `ProcessManager.cachedVMDisk: VMDiskInfo?` (private(set)), `func refreshVMDisk() async`, init-параметр `diskProbe: any VMDiskProbing = LiveVMDiskProbe()`, `vmDiskMonitoringEnabled` НЕ добавляется — гейт существующий `isVMMonitoringEnabled()`.

- [ ] **Step 1: Write the fake + failing test**

`DevDeckTests/Support/FakeVMDiskProbe.swift`:

```swift
import Foundation
@testable import DevDeck

/// Returns the scripted disk info; counts samples.
final class FakeVMDiskProbe: VMDiskProbing, @unchecked Sendable {
    var info: VMDiskInfo?
    private(set) var sampleCount = 0
    init(_ info: VMDiskInfo? = nil) { self.info = info }
    func sample() -> VMDiskInfo? { sampleCount += 1; return info }
}
```

Дописать в `DevDeckTests/VMDiskTests.swift`:

```swift
@MainActor
final class ProcessManagerDiskTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    func testRefreshVMDiskPopulatesCache() async {
        let probe = FakeVMDiskProbe(VMDiskInfo(usedBytes: 40 * gib, totalBytes: 97 * gib))
        let m = ProcessManager(runner: FakeCommandRunner(), diskProbe: probe)
        await m.refreshVMDisk()
        XCTAssertEqual(m.cachedVMDisk, VMDiskInfo(usedBytes: 40 * gib, totalBytes: 97 * gib))
    }

    func testRefreshVMDiskClearsWhenDisabled() async {
        let probe = FakeVMDiskProbe(VMDiskInfo(usedBytes: 40 * gib, totalBytes: 97 * gib))
        let m = ProcessManager(runner: FakeCommandRunner(),
                               vmMonitoringEnabled: { false }, diskProbe: probe)
        await m.refreshVMDisk()
        XCTAssertNil(m.cachedVMDisk)
        XCTAssertEqual(probe.sampleCount, 0)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `no member 'refreshVMDisk'` / `extra argument 'diskProbe'`.

- [ ] **Step 3: Implement**

В блоке полей (рядом с `cachedClusterHealth`, ~строка 179):

```swift
    // MARK: VM disk
    @ObservationIgnored private let diskProbe: any VMDiskProbing
    /// Last VM-disk snapshot for the popover; refreshed while the popover is open
    /// (15 s cadence) and by the sampler during runs.
    private(set) var cachedVMDisk: VMDiskInfo?
```

В init: параметр `diskProbe: any VMDiskProbing = LiveVMDiskProbe()` (после `clusterHealthEnabled`), в теле — `self.diskProbe = diskProbe`.

Рядом с `refreshClusterHealth()`:

```swift
    /// Update cachedVMDisk by running the blocking ssh probe OFF the main thread.
    /// Gated by the same toggle as the colima memory metric. Called while the popover is open.
    func refreshVMDisk() async {
        guard isVMMonitoringEnabled() else { cachedVMDisk = nil; return }
        let probe = diskProbe
        cachedVMDisk = await Task.detached(priority: .utility) { probe.sample() }.value
    }
```

- [ ] **Step 4: Run to verify it passes** (`-only-testing:DevDeckTests/ProcessManagerDiskTests`)

---

### Task 3: Уведомление о диске + подсадка в сэмплер

**Files:**
- Modify: `DevDeck/Diagnostics/Notifier.swift` (enum, ~строка 12)
- Modify: `DevDeck/Diagnostics/LiveNotifier.swift` (switch, после `case .memoryThreshold` ~строка 52)
- Modify: `DevDeck/Localization/L10n.swift` (рядом с `notifMemoryHigh`)
- Modify: `DevDeck/Process/ProcessManager.swift` (`checkDiskThreshold` рядом с `checkMemoryThresholds` ~строка 845; сэмплер `startVMSamplerIfNeeded` ~строки 1046–1070)
- Test: `DevDeckTests/VMDiskTests.swift` (дописать тест в `ProcessManagerDiskTests`)

**Interfaces:**
- Consumes: `VMDiskInfo` (Task 1), `cachedVMDisk`/`diskProbe` (Task 2), существующие `warnedThresholds`, `memoryWarnThreshold`, `notifier`.
- Produces: `AppNotification.diskThreshold(detail: String)`, `ProcessManager.checkDiskThreshold(_ disk: VMDiskInfo?)`, `L10n.notifDiskFull`, `L10n.diskPruneAdvice`.

- [ ] **Step 1: Write the failing test**

```swift
    func testDiskThresholdNotifiesOncePerRun() {
        let notifier = FakeNotifier()
        let m = ProcessManager(runner: FakeCommandRunner(), notifier: notifier)

        // 92% (>= 90%) → one warning; repeat must NOT re-notify (debounced per run).
        m.checkDiskThreshold(VMDiskInfo(usedBytes: 92 * gib, totalBytes: 100 * gib))
        m.checkDiskThreshold(VMDiskInfo(usedBytes: 95 * gib, totalBytes: 100 * gib))
        // Below threshold and nil never notify.
        m.checkDiskThreshold(VMDiskInfo(usedBytes: 50 * gib, totalBytes: 100 * gib))
        m.checkDiskThreshold(nil)

        XCTAssertEqual(notifier.posted.count, 1)
        guard case .diskThreshold = notifier.posted.first else {
            return XCTFail("expected diskThreshold, got \(notifier.posted)")
        }
    }
```

- [ ] **Step 2: Run to verify it fails** — `no member 'checkDiskThreshold'`.

- [ ] **Step 3: Implement**

`Notifier.swift`, в enum после `memoryThreshold`:

```swift
    case diskThreshold(detail: String)                   // colima VM docker disk almost full mid-run
```

`LiveNotifier.swift`, в switch после `case .memoryThreshold`:

```swift
        case .diskThreshold(let detail):
            content.title = L10n.notifDiskFull
            content.body = detail + " · " + L10n.diskPruneAdvice
            content.sound = .default
```

`L10n.swift`, рядом с `notifMemoryHigh`:

```swift
    static var notifDiskFull: String {
        t("colima VM disk almost full", "Диск colima VM почти заполнен")
    }
    static var diskPruneAdvice: String {
        t("builds will slow down — run docker prune", "сборки замедлятся — рекомендуется docker prune")
    }
```

`ProcessManager.swift`, после `checkMemoryThresholds`:

```swift
    /// One disk warning per sampler session (same debounce set as the memory warnings):
    /// a full docker disk degrades builds into buildkit GC churn.
    func checkDiskThreshold(_ disk: VMDiskInfo?) {
        guard let disk, disk.fraction >= memoryWarnThreshold,
              warnedThresholds.insert("disk").inserted else { return }
        notifier.post(.diskThreshold(detail: disk.format()))
        DiagnosticLog.shared.log("colima disk high: \(disk.format())", level: .warn)
    }
```

Сэмплер (`startVMSamplerIfNeeded`): перед `while` добавить `var diskTick = 0`, внутри цикла после блока `checkMemoryThresholds(...)`:

```swift
                // Disk changes slowly and the ssh probe isn't free: every ~15 ticks (≈15 s),
                // so the disk warning fires even with the popover closed.
                if self.isVMMonitoringEnabled(), diskTick % 15 == 0 {
                    let diskProbe = self.diskProbe
                    let disk = await Task.detached(priority: .utility) { diskProbe.sample() }.value
                    if let disk { self.cachedVMDisk = disk }
                    self.checkDiskThreshold(disk)
                }
                diskTick += 1
```

- [ ] **Step 4: Run to verify it passes**, плюс `-only-testing:DevDeckTests/ProcessManagerNotificationTests` (не сломан ли существующий debounce).

---

### Task 4: refreshHostSample — живые «Давление»/«Скорость свопа»

**Files:**
- Modify: `DevDeck/Process/ProcessManager.swift` (рядом с `refreshVMSample` ~строка 875)
- Modify: `DevDeck/Diagnostics/HostMetrics.swift` (снять TODO-комментарий на строках 25–26)
- Test: `DevDeckTests/VMDiskTests.swift` → класс `ProcessManagerHostRefreshTests`

**Interfaces:**
- Consumes: существующие `hostProbe`, `updateSwapRate(cur:now:)`, `cachedHostSample`, `FakeHostMetricsProbe` (`DevDeckTests/Support/`).
- Produces: `func refreshHostSample() async` — no-op при выключенном `isHostMonitoringEnabled()` или активной сборке.

- [ ] **Step 1: Write the failing test**

```swift
@MainActor
final class ProcessManagerHostRefreshTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    private func sample(swapOuts: UInt64) -> HostMetricsSample {
        HostMetricsSample(pressure: .normal, swapInsPages: 0, swapOutsPages: swapOuts,
                          compressorPages: 0, totalBytes: 16 * gib, buildFootprintBytes: 0)
    }

    func testRefreshHostSamplePopulatesCacheAndRate() async {
        let probe = FakeHostMetricsProbe([sample(swapOuts: 0), sample(swapOuts: 1000)])
        let m = ProcessManager(runner: FakeCommandRunner(), hostProbe: probe)

        await m.refreshHostSample()
        XCTAssertNotNil(m.cachedHostSample)
        XCTAssertNil(m.cachedSwapOutRatePages)   // first call only records the baseline

        await m.refreshHostSample()
        XCTAssertEqual(m.cachedHostSample?.swapOutsPages, 1000)
        let rate = try! XCTUnwrap(m.cachedSwapOutRatePages)
        XCTAssertGreaterThan(rate, 0)            // 1000 pages over a sub-second dt
        XCTAssertNil(probe.lastBuildPID)         // outside a run there is no build PID
    }

    func testRefreshHostSampleNoopWhenDisabled() async {
        let probe = FakeHostMetricsProbe([sample(swapOuts: 0)])
        let m = ProcessManager(runner: FakeCommandRunner(),
                               hostProbe: probe, hostMonitoringEnabled: { false })
        await m.refreshHostSample()
        XCTAssertNil(m.cachedHostSample)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `no member 'refreshHostSample'`.

- [ ] **Step 3: Implement** (рядом с `refreshVMSample`)

```swift
    /// Update cachedHostSample + the swap rate while the popover is open and no run is active
    /// (during a run the 1 s sampler owns these caches — two writers would corrupt the rate).
    func refreshHostSample() async {
        guard isHostMonitoringEnabled(), active.isEmpty else { return }
        let probe = hostProbe
        let host = await Task.detached(priority: .utility) { probe.sample(buildPID: nil) }.value
        guard active.isEmpty else { return }   // a run may have started during the await
        cachedHostSample = host
        updateSwapRate(cur: host, now: Date())
    }
```

В `HostMetrics.swift` удалить строки TODO (25–26: «TODO(deferred): the sampler doesn't yet retain…») — комментарий больше не соответствует действительности; краткое описание rate-функции оставить.

- [ ] **Step 4: Run to verify it passes** (`-only-testing:DevDeckTests/ProcessManagerHostRefreshTests`)

---

### Task 5: SwapSeverity — порог для «Свопа»

**Files:**
- Modify: `DevDeck/Diagnostics/SystemMemory.swift`
- Test: `DevDeckTests/VMDiskTests.swift` → класс `SwapSeverityTests`

**Interfaces:**
- Produces: `enum SwapSeverity { case normal, elevated, high }`, `SystemMemory.swapSeverity(swapUsedBytes:totalRAMBytes:) -> SwapSeverity`.

- [ ] **Step 1: Write the failing test**

```swift
final class SwapSeverityTests: XCTestCase {
    private let gib: UInt64 = 1_073_741_824

    func testThresholds() {
        let ram = 64 * gib
        // < 10% of RAM — macOS keeping a couple of GB swapped is healthy.
        XCTAssertEqual(SystemMemory.swapSeverity(swapUsedBytes: 0, totalRAMBytes: ram), .normal)
        XCTAssertEqual(SystemMemory.swapSeverity(swapUsedBytes: 6 * gib, totalRAMBytes: ram), .normal)
        // >= 10% — elevated.
        XCTAssertEqual(SystemMemory.swapSeverity(swapUsedBytes: 64 * gib / 10, totalRAMBytes: ram), .elevated)
        // >= 25% — high.
        XCTAssertEqual(SystemMemory.swapSeverity(swapUsedBytes: 16 * gib, totalRAMBytes: ram), .high)
        // Zero RAM (syscall failure) must not crash → normal.
        XCTAssertEqual(SystemMemory.swapSeverity(swapUsedBytes: gib, totalRAMBytes: 0), .normal)
    }
}
```

- [ ] **Step 2: Run to verify it fails** — `cannot find 'SwapSeverity'`.

- [ ] **Step 3: Implement** (в `SystemMemory.swift`, после `swapUsedBytes()`)

```swift
/// How alarming the swap usage is, as a fraction of physical RAM (machine-independent):
/// a couple of swapped GB is normal macOS housekeeping, not a signal.
enum SwapSeverity { case normal, elevated, high }

extension SystemMemory {
    static func swapSeverity(swapUsedBytes: UInt64, totalRAMBytes: UInt64) -> SwapSeverity {
        guard totalRAMBytes > 0 else { return .normal }
        let fraction = Double(swapUsedBytes) / Double(totalRAMBytes)
        if fraction >= 0.25 { return .high }
        if fraction >= 0.10 { return .elevated }
        return .normal
    }
}
```

- [ ] **Step 4: Run to verify it passes** (`-only-testing:DevDeckTests/SwapSeverityTests`)

---

### Task 6: PopoverView + L10n — ячейки и циклы

**Files:**
- Modify: `DevDeck/MenuBar/PopoverView.swift` (задача ~строки 20–26 и 85–90, ячейки ~строки 132–135 и 153–155)
- Modify: `DevDeck/Localization/L10n.swift` (`diskVM` добавить, `compressor` удалить, ~строка 315)

**Interfaces:**
- Consumes: `manager.cachedVMDisk`, `manager.refreshVMDisk()`, `manager.refreshHostSample()`, `SystemMemory.swapSeverity`, `VMDiskInfo.format()`.
- Produces: `L10n.diskVM`.

- [ ] **Step 1: L10n** — рядом с `pressure` добавить, `compressor` удалить:

```swift
    static var diskVM: String { t("VM disk", "Диск VM") }
```

- [ ] **Step 2: 15-секундный цикл** (строки 21–25) — добавить диск к health-обновлению:

```swift
                    // Refresh colima/minikube health and the VM disk while the popover is open.
                    while !Task.isCancelled {
                        await manager.refreshClusterHealth()
                        await manager.refreshVMDisk()
                        try? await Task.sleep(for: .seconds(15))
                    }
```

- [ ] **Step 3: 2-секундный цикл** (строки 86–89) — добавить хост-сэмпл:

```swift
            while !Task.isCancelled {
                await manager.refreshVMSample()
                await manager.refreshHostSample()
                try? await Task.sleep(for: .seconds(2))
            }
```

- [ ] **Step 4: Ячейка «Своп»** (строки 132–135) — цвет по порогу:

```swift
                    let hasSwap = memory.swapUsedBytes > 0
                    let swapColor: Color = switch SystemMemory.swapSeverity(
                        swapUsedBytes: memory.swapUsedBytes, totalRAMBytes: memory.totalBytes) {
                    case .normal: .secondary
                    case .elevated: .orange
                    case .high: .red
                    }
                    metricCell(L10n.swap,
                               hasSwap ? SystemMemory.formatGiB(memory.swapUsedBytes) : "",
                               color: hasSwap ? swapColor : Self.placeholderColor)
```

- [ ] **Step 5: Ячейка «Компрессор» → «Диск VM»** (строки 153–155) — заменить целиком:

```swift
                    let disk = manager.cachedVMDisk
                    metricCell(L10n.diskVM,
                               disk.map { $0.format() } ?? "",
                               color: disk.map { pressureColor($0.fraction) } ?? Self.placeholderColor)
```

- [ ] **Step 6: Build** — приложение собирается без предупреждений о неиспользуемом `L10n.compressor`:

```bash
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild build -project DevDeck.xcodeproj \
  -scheme DevDeck -destination 'platform=macOS' -quiet 2>&1 | tail -5
```

---

### Task 7: Полный прогон и финал

- [ ] **Step 1: Весь набор тестов**

```bash
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj \
  -scheme DevDeck -destination 'platform=macOS' -quiet 2>&1 | tail -20
```

Expected: `TEST SUCCEEDED`, ноль упавших (включая существующие `HostMetricsTests`, `ProcessManagerNotificationTests`).

- [ ] **Step 2: Ручная проверка** — запустить собранный DevDeck, открыть попап: ячейка «Диск VM» показывает актуальные проценты (сверить с `colima ssh -- df -h /var/lib/docker`), «Давление» и «Скорость свопа» не пустые без сборки, «Своп» серый при паре ГБ, «Компрессора» нет.

- [ ] **Step 3: Предложить пользователю коммит** (не коммитить самостоятельно — конвенция проекта).

## Self-Review (выполнено при написании)

- Покрытие спеки: изменение 1 → Tasks 1–3, 6; изменение 2 → Task 4; изменение 3 → Task 5, 6; изменение 4 → Task 6. Настройки — гейты в Tasks 2–4. Тесты — в каждой задаче.
- Заглушек нет; сигнатуры между задачами сверены (`VMDiskInfo`, `refreshVMDisk`, `checkDiskThreshold`, `refreshHostSample`, `SwapSeverity`).
