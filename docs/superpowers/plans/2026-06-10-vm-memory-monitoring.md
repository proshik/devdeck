# VM Memory Monitoring (colima) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Display colima VM memory (hypervisor RSS vs limit) as a live line in the popover and as a peak-per-run in the diagnostic log, behind a global flag in config.json — the first increment of the right-sizing advisor.

**Architecture:** A `VMMemoryProbing` provider (`LiveVMMemoryProbe`: `pgrep` for the `com.apple.Virtualization.VirtualMachine` process + `proc_pid_rusage` footprint + limit from `colima list --json`, with a PID/limit cache) lives in `ProcessManager`. The popover reads the value via `manager.vmMemorySample()` (gated by the flag in one place). The sampler in `ProcessManager` accumulates the VM-RSS peak for each run and writes it to `DiagnosticLog` on termination. The flag is the field `Config.settings.vmMemoryMonitoring` (config.json), toggled in the main window's "Settings" pane.

**Tech Stack:** Swift, SwiftUI/AppKit, `Foundation.Process` (pgrep/colima), `proc_pid_rusage`, existing `ProcessTree`, `SystemMemory`, `DiagnosticLog`, `ConfigCodec`, `TimelineView`.

---

## File Structure

- **Create** `DevDeck/Diagnostics/VMMemory.swift` — `VMMemoryInfo` (model + format), `VMMemoryProbing` (protocol), `LiveVMMemoryProbe`, limit parsing.
- **Modify** `DevDeck/Process/ProcessTree.swift` — add `physFootprint(_:)`.
- **Modify** `DevDeck/Models/Config.swift` — add `Settings` + `Config.settings`.
- **Modify** `DevDeck/Store/CommandStore.swift` — `setVMMonitoring(_:)`.
- **Modify** `DevDeck/Process/ProcessManager.swift` — inject `probe` + `isVMMonitoringEnabled`, `vmMemorySample()`, peak sampler.
- **Modify** `DevDeck/AppDelegate.swift` — shared probe, wiring the flag from `store`.
- **Modify** `DevDeck/MenuBar/PopoverView.swift` — VM row in `memoryHeader`.
- **Create** `DevDeck/MainWindow/SettingsView.swift` + **Modify** `DevDeck/MainWindow/MainWindowView.swift` — "Settings" item with a toggle.
- **Create** tests: `DevDeckTests/VMMemoryTests.swift`, `DevDeckTests/ProcessManagerVMSamplerTests.swift`, `DevDeckTests/Support/FakeVMMemoryProbe.swift`; **Modify** `DevDeckTests/ConfigCodecTests.swift`.

---

### Task 1: Config flag — `Config.settings`

**Files:**
- Modify: `DevDeck/Models/Config.swift`
- Test: `DevDeckTests/ConfigCodecTests.swift`

- [ ] **Step 1: Round-trip and default test** — add to `ConfigCodecTests`:

```swift
func testSettingsRoundTripAndDefault() throws {
    // missing settings → default vmMemoryMonitoring = true
    let json = Data(#"{"commands":[],"chains":[]}"#.utf8)
    XCTAssertTrue(try ConfigCodec.decode(json).settings.vmMemoryMonitoring)

    // explicit false round-trips correctly
    var cfg = Config.empty
    cfg.settings.vmMemoryMonitoring = false
    let data = try ConfigCodec.encode(cfg)
    XCTAssertFalse(try ConfigCodec.decode(data).settings.vmMemoryMonitoring)
}
```

- [ ] **Step 2: Run — should fail** (`Value of type 'Config' has no member 'settings'`):

Run: `xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/ConfigCodecTests/testSettingsRoundTripAndDefault`
Expected: FAIL (build error / no member).

- [ ] **Step 3: Add `Settings` and the field to `Config.swift`.** Following the `Command` pattern
(custom `init(from:)` with `decodeIfPresent ?? default`), add:

```swift
struct Settings: Codable, Equatable {
    var vmMemoryMonitoring: Bool

    init(vmMemoryMonitoring: Bool = true) {
        self.vmMemoryMonitoring = vmMemoryMonitoring
    }

    enum CodingKeys: String, CodingKey { case vmMemoryMonitoring }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vmMemoryMonitoring = try c.decodeIfPresent(Bool.self, forKey: .vmMemoryMonitoring) ?? true
    }
}
```

In `struct Config`: add `var settings: Settings`, in its `init` add the parameter `settings: Settings = Settings()`, in `CodingKeys` add `case settings`, in `init(from:)` add `settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()`. Ensure `Config.empty` still compiles (settings will use its default).

- [ ] **Step 4: Run — should pass.**

Run: same `-only-testing:DevDeckTests/ConfigCodecTests/testSettingsRoundTripAndDefault`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Models/Config.swift DevDeckTests/ConfigCodecTests.swift
git commit -m "Config.settings.vmMemoryMonitoring (VM monitoring flag, default on)"
```

---

### Task 2: `VMMemoryInfo` model + colima limit parsing

**Files:**
- Create: `DevDeck/Diagnostics/VMMemory.swift`
- Test: `DevDeckTests/VMMemoryTests.swift`

- [ ] **Step 1: Format/fraction/parsing tests** — create `VMMemoryTests.swift`:

```swift
import XCTest
@testable import DevDeck

final class VMMemoryTests: XCTestCase {
    func testFractionAndHeadroom() {
        let i = VMMemoryInfo(usedBytes: 7 * 1_073_741_824, limitBytes: 10 * 1_073_741_824)
        XCTAssertEqual(i.fraction, 0.7, accuracy: 0.001)
        XCTAssertEqual(i.headroomFraction, 0.3, accuracy: 0.001)
    }

    func testFormatBinaryGiB() {
        let i = VMMemoryInfo(usedBytes: 6_871_947_674, limitBytes: 10 * 1_073_741_824) // ~6.4
        XCTAssertEqual(i.format(), "6.4 / 10 GiB · 64%")
    }

    func testParseColimaLimit() {
        let json = #"{"name":"default","status":"Running","memory":10737418240,"cpus":6}"#
        XCTAssertEqual(VMMemoryInfo.parseColimaLimitBytes(json), 10_737_418_240)
        XCTAssertNil(VMMemoryInfo.parseColimaLimitBytes("not json"))
    }
}
```

- [ ] **Step 2: Run — should fail** (no `VMMemoryInfo` type).

Run: `xcodebuild test ... -only-testing:DevDeckTests/VMMemoryTests`
Expected: FAIL (no such type).

- [ ] **Step 3: Implement the model and parsing** — `DevDeck/Diagnostics/VMMemory.swift`:

```swift
import Foundation

/// VM memory (hypervisor RSS vs limit). Binary GiB — same as SystemMemory.
struct VMMemoryInfo: Equatable {
    let usedBytes: UInt64
    let limitBytes: UInt64

    var fraction: Double { limitBytes > 0 ? Double(usedBytes) / Double(limitBytes) : 0 }
    var headroomFraction: Double { max(0, 1 - fraction) }

    func format() -> String {
        let gib = 1_073_741_824.0
        let percent = limitBytes > 0 ? Int((fraction * 100).rounded()) : 0
        return String(format: "%.1f / %.0f GiB · %d%%",
                      Double(usedBytes) / gib, Double(limitBytes) / gib, percent)
    }

    /// Limit from `colima list --json` (field `memory`, bytes). nil on failure/malformed JSON.
    static func parseColimaLimitBytes(_ json: String) -> UInt64? {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let mem = obj["memory"] as? NSNumber else { return nil }
        let v = mem.uint64Value
        return v > 0 ? v : nil
    }
}
```

- [ ] **Step 4: Run — should pass.**

Run: `-only-testing:DevDeckTests/VMMemoryTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Diagnostics/VMMemory.swift DevDeckTests/VMMemoryTests.swift
git commit -m "VMMemoryInfo: format/fraction/headroom + colima limit parsing"
```

---

### Task 3: `ProcessTree.physFootprint`

**Files:**
- Modify: `DevDeck/Process/ProcessTree.swift`

- [ ] **Step 1: Add the function** (no separate unit test needed — it wraps a syscall;
covered by probe integration). In `enum ProcessTree` add:

```swift
/// Physical footprint of a process (bytes) via proc_pid_rusage(RUSAGE_INFO_V2). 0 on failure.
static func physFootprint(_ pid: Int32) -> UInt64 {
    guard pid > 0 else { return 0 }
    var info = rusage_info_v2()
    let rc = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: (rusage_info_t?).self, capacity: 1) {
            proc_pid_rusage(pid, RUSAGE_INFO_V2, $0)
        }
    }
    return rc == 0 ? info.ri_phys_footprint : 0
}
```

Ensure `import Darwin` is present at the top of the file (for `proc_pid_rusage`). If not — add it.

- [ ] **Step 2: Build** (no tests — verify compilation):

Run: `xcodebuild build -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add DevDeck/Process/ProcessTree.swift
git commit -m "ProcessTree.physFootprint (proc_pid_rusage)"
```

---

### Task 4: `VMMemoryProbing` + `LiveVMMemoryProbe`

**Files:**
- Modify: `DevDeck/Diagnostics/VMMemory.swift`
- Create: `DevDeckTests/Support/FakeVMMemoryProbe.swift`

- [ ] **Step 1: Fake for tests** — `DevDeckTests/Support/FakeVMMemoryProbe.swift`:

```swift
import Foundation
@testable import DevDeck

/// Programmable probe: returns pre-set samples in order (last one repeats).
final class FakeVMMemoryProbe: VMMemoryProbing, @unchecked Sendable {
    private var samples: [VMMemoryInfo?]
    private(set) var calls = 0
    init(_ samples: [VMMemoryInfo?]) { self.samples = samples }
    func sample() -> VMMemoryInfo? {
        defer { calls += 1 }
        guard !samples.isEmpty else { return nil }
        return calls < samples.count ? samples[calls] : samples.last!
    }
}
```

- [ ] **Step 2: Protocol + live implementation** — add to `DevDeck/Diagnostics/VMMemory.swift`:

```swift
/// VM memory snapshot. Behind a protocol → ProcessManager/popover can be tested with a fake.
protocol VMMemoryProbing: Sendable {
    func sample() -> VMMemoryInfo?
}

/// Real probe: colima hypervisor process (vz) + its footprint + colima limit.
/// Caches PID and limit (each tick = footprint only, no process spawning).
final class LiveVMMemoryProbe: VMMemoryProbing, @unchecked Sendable {
    private let lock = NSLock()
    private var cachedPID: Int32?
    private var cachedLimit: UInt64?

    func sample() -> VMMemoryInfo? {
        lock.lock(); defer { lock.unlock() }
        guard let pid = resolvePID() else { return nil }
        guard let limit = resolveLimit() else { return nil }
        let used = ProcessTree.physFootprint(pid)
        guard used > 0 else { return nil }
        return VMMemoryInfo(usedBytes: used, limitBytes: limit)
    }

    private func resolvePID() -> Int32? {
        if let pid = cachedPID, ProcessTree.isAlive(pid) { return pid }
        // pgrep -f: PID(s) of the vz VM process; take the one with the highest RSS.
        guard let out = ProcessTree.run("/usr/bin/pgrep",
            ["-f", "com.apple.Virtualization.VirtualMachine"]) else { cachedPID = nil; return nil }
        let pids = out.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        let best = pids.max(by: { ProcessTree.physFootprint($0) < ProcessTree.physFootprint($1) })
        cachedPID = best
        return best
    }

    private func resolveLimit() -> UInt64? {
        if let limit = cachedLimit { return limit }
        guard let json = ProcessTree.run("/opt/homebrew/bin/colima", ["list", "--json"])
                ?? ProcessTree.run("/usr/bin/env", ["colima", "list", "--json"]) else { return nil }
        // colima list --json prints one JSON object per line per profile; take the first "default"/first.
        let line = json.split(whereSeparator: \.isNewline).first.map(String.init) ?? json
        cachedLimit = VMMemoryInfo.parseColimaLimitBytes(line)
        return cachedLimit
    }
}
```

- [ ] **Step 3: Build** (Live is not unit-tested — depends on the environment; fake is used in Task 5):

Run: `xcodebuild build -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Commit**

```bash
git add DevDeck/Diagnostics/VMMemory.swift DevDeckTests/Support/FakeVMMemoryProbe.swift
git commit -m "VMMemoryProbing + LiveVMMemoryProbe (pgrep vz + footprint + colima limit, cache)"
```

---

### Task 5: Peak sampler + `vmMemorySample()` in `ProcessManager`

**Files:**
- Modify: `DevDeck/Process/ProcessManager.swift`
- Test: `DevDeckTests/ProcessManagerVMSamplerTests.swift`

- [ ] **Step 1: Peak logic test** — `ProcessManagerVMSamplerTests.swift`. Make the sampler
testable WITHOUT a real timer: extract the peak logic into a pure method `recordVMSample(for:)`
that the test calls directly, then verify the diagnostic log on termination.

```swift
import XCTest
@testable import DevDeck

@MainActor
final class ProcessManagerVMSamplerTests: XCTestCase {
    private func cmd() -> Command { Command(id: UUID(), name: "build", command: "echo") }

    func testPeakAccumulatesAndLogsOnTerminate() async {
        let fake = FakeCommandRunner()
        let gib: UInt64 = 1_073_741_824
        let probe = FakeVMMemoryProbe([
            VMMemoryInfo(usedBytes: 4 * gib, limitBytes: 10 * gib),
            VMMemoryInfo(usedBytes: 7 * gib, limitBytes: 10 * gib),   // peak
            VMMemoryInfo(usedBytes: 5 * gib, limitBytes: 10 * gib),
        ])
        let m = ProcessManager(runner: fake, vmProbe: probe, vmMonitoringEnabled: { true })
        let c = cmd()
        fake.eagerScripts[c.id] = [.started(pid: 1)]
        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        await yieldUntil { m.states[c.id] == .running }

        m.recordVMSample(for: c.id)   // 4
        m.recordVMSample(for: c.id)   // 7 (peak)
        m.recordVMSample(for: c.id)   // 5
        XCTAssertEqual(m.vmPeakBytes(for: c.id), 7 * gib)

        ctrl.terminate(0)
        await yieldUntil { m.states[c.id] == .succeeded }
        XCTAssertNil(m.vmPeakBytes(for: c.id), "peak is cleared on termination")
    }

    func testDisabledFlagSkipsSampling() {
        let m = ProcessManager(runner: FakeCommandRunner(),
                               vmProbe: FakeVMMemoryProbe([VMMemoryInfo(usedBytes: 9, limitBytes: 10)]),
                               vmMonitoringEnabled: { false })
        let id = UUID()
        m.recordVMSample(for: id)
        XCTAssertNil(m.vmPeakBytes(for: id))
    }
}
```

- [ ] **Step 2: Run — should fail** (missing init parameters/methods).

Run: `-only-testing:DevDeckTests/ProcessManagerVMSamplerTests`
Expected: FAIL.

- [ ] **Step 3: Implement in `ProcessManager`.**

(a) Add parameters to init (with defaults so existing tests don't break):
`vmProbe: any VMMemoryProbing = LiveVMMemoryProbe()`, `vmMonitoringEnabled: @escaping () -> Bool = { true }`.
Store as `@ObservationIgnored private let vmProbe` and `@ObservationIgnored private var isVMMonitoringEnabled`. (Make `isVMMonitoringEnabled` a `var` so AppDelegate can re-assign it — see Task 6; or accept it through init.)

(b) State: `@ObservationIgnored private var vmPeak: [UUID: VMMemoryInfo] = [:]`.

(c) Methods:

```swift
/// Snapshot for the popover (gated by flag).
func vmMemorySample() -> VMMemoryInfo? {
    isVMMonitoringEnabled() ? vmProbe.sample() : nil
}

/// One VM-RSS sample for run id (called by the sampler timer). Pure for tests.
func recordVMSample(for id: UUID) {
    guard isVMMonitoringEnabled(), let s = vmProbe.sample() else { return }
    if let prev = vmPeak[id], prev.usedBytes >= s.usedBytes { return }
    vmPeak[id] = s
}

func vmPeakBytes(for id: UUID) -> UInt64? { vmPeak[id]?.usedBytes }

/// Log and clear the peak for a run (called on termination).
private func flushVMPeak(_ id: UUID, name: String) {
    guard let peak = vmPeak.removeValue(forKey: id) else { return }
    let headroom = Int((peak.headroomFraction * 100).rounded())
    var hint = ""
    if peak.headroomFraction > 0.30 { hint = " — colima --memory can be lowered" }
    else if peak.headroomFraction < 0.10 { hint = " — very tight, raise colima --memory" }
    DiagnosticLog.shared.log("VM peak for «\(name)»: \(peak.format()) (headroom \(headroom)%)\(hint)")
}
```

(d) Starting/stopping the sampler timer. Add:

```swift
@ObservationIgnored private var vmSamplerTask: Task<Void, Never>?

private func startVMSamplerIfNeeded() {
    guard isVMMonitoringEnabled(), vmSamplerTask == nil else { return }
    vmSamplerTask = Task { @MainActor [weak self] in
        while let self, !self.active.isEmpty {
            for id in self.active.keys { self.recordVMSample(for: id) }
            try? await Task.sleep(for: .seconds(1))
        }
        self?.vmSamplerTask = nil
    }
}
```

Call `startVMSamplerIfNeeded()` in `apply` in the `.started` case (for any command). In the `.terminated` and `.cancelled` cases (both branches) call `flushVMPeak(commandID, name: name)` — alongside the existing cleanup. The sampler shuts itself down when `active` is empty.

(Note: `active` holds managed runs; terminal commands also have an entry, so the VM peak will be collected for runs launched in Ghostty as well.)

- [ ] **Step 4: Run — should pass.** Then run the full suite — old tests must not be broken
(new init parameters have defaults).

Run: `-only-testing:DevDeckTests/ProcessManagerVMSamplerTests`, then full `xcodebuild test`.
Expected: PASS; full suite green.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Process/ProcessManager.swift DevDeckTests/ProcessManagerVMSamplerTests.swift
git commit -m "ProcessManager: VM peak sampler per run + vmMemorySample() (gated by flag)"
```

---

### Task 6: Flag wiring from the store (`CommandStore` + `AppDelegate`)

**Files:**
- Modify: `DevDeck/Store/CommandStore.swift`
- Modify: `DevDeck/AppDelegate.swift`
- Test: `DevDeckTests/CommandStoreMutationTests.swift`

- [ ] **Step 1: Mutator test** — add to `CommandStoreMutationTests`:

```swift
func testSetVMMonitoringPersists() {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = CommandStore(configURL: url)
    store.setVMMonitoring(false)
    XCTAssertFalse(store.config.settings.vmMemoryMonitoring)
    // re-read from disk — persisted
    let store2 = CommandStore(configURL: url)
    store2.reload()
    XCTAssertFalse(store2.config.settings.vmMemoryMonitoring)
}
```

- [ ] **Step 2: Run — should fail** (no `setVMMonitoring`).

Run: `-only-testing:DevDeckTests/CommandStoreMutationTests/testSetVMMonitoringPersists`
Expected: FAIL.

- [ ] **Step 3: Implement.** In `CommandStore` add (next to `upsert`/`delete`, using the
existing private `save()`):

```swift
func setVMMonitoring(_ on: Bool) {
    guard config.settings.vmMemoryMonitoring != on else { return }
    config.settings.vmMemoryMonitoring = on
    save()
}
```

(If `config` is declared `private(set)` — mutation inside a store method is fine. If `save()` has a different name — use the same method as `upsert`. Cross-reference the file.)

In `AppDelegate.applicationDidFinishLaunching` (after creating `manager` and `store`), wire the flag into the manager. Add the shared probe and re-assign the closure:

```swift
manager.isVMMonitoringEnabled = { [weak store] in store?.config.settings.vmMemoryMonitoring ?? false }
```

(For this, `ProcessManager.isVMMonitoringEnabled` must be a `var` with default `{ true }` —
see Task 5. Leave the probe as the default `LiveVMMemoryProbe()` inside the manager.)

- [ ] **Step 4: Run — should pass.**

Run: `-only-testing:DevDeckTests/CommandStoreMutationTests/testSetVMMonitoringPersists`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Store/CommandStore.swift DevDeck/AppDelegate.swift DevDeckTests/CommandStoreMutationTests.swift
git commit -m "CommandStore.setVMMonitoring + flag wiring into ProcessManager"
```

---

### Task 7: Live VM row in the popover

**Files:**
- Modify: `DevDeck/MenuBar/PopoverView.swift`

- [ ] **Step 1: Add the row** to `memoryHeader`, INSIDE the `TimelineView` closure, after the
swap row (mirroring its pattern). Since the row depends on the flag and VM availability:

```swift
if let vm = manager.vmMemorySample() {
    HStack {
        Text("VM colima").foregroundStyle(.secondary)
        Spacer()
        Text(vm.format())
            .monospacedDigit()
            .foregroundStyle(pressureColor(vm.fraction))
    }
    .font(.system(size: 10))
}
```

`manager` is already available as `@Environment(ProcessManager.self)`. `pressureColor(_:)` already exists in `PopoverView`. The flag and VM availability are gated inside `vmMemorySample()` (→ nil → row is hidden).

- [ ] **Step 2: Build + run the app** — visually verify: with colima running, the popover header
shows "VM colima X / 10 GiB · NN%"; setting `settings.vmMemoryMonitoring=false` in config.json
makes the row disappear after the FileWatcher picks up the change.

Run: `xcodebuild build ...`; launch `.app`, open the popover.
Expected: VM row appears/disappears based on the flag.

- [ ] **Step 3: Commit**

```bash
git add DevDeck/MenuBar/PopoverView.swift
git commit -m "Popover: live VM colima row (RSS vs limit, colour by fraction)"
```

---

### Task 8: "Settings" UI with a toggle

**Files:**
- Create: `DevDeck/MainWindow/SettingsView.swift`
- Modify: `DevDeck/MainWindow/MainWindowView.swift`

- [ ] **Step 1: `SettingsView`** — a toggle that writes to the store:

```swift
import SwiftUI

/// Global application settings (persisted in config.json).
struct SettingsView: View {
    @Environment(CommandStore.self) private var store

    var body: some View {
        Form {
            Section("Memory Monitoring") {
                Toggle("Show VM memory (colima) and peak per run", isOn: Binding(
                    get: { store.config.settings.vmMemoryMonitoring },
                    set: { store.setVMMonitoring($0) }
                ))
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}
```

- [ ] **Step 2: Settings item in the `MainWindowView` sidebar.** Check how navigation is structured
(`List`/`NavigationSplitView`, selection enum). Add a "Settings" item (e.g. via a separate
enum case or a static sidebar section) that shows `SettingsView()`. Follow the existing
command/chain selection pattern. Specifically: add a "⚙︎ Settings" button row at the top of the
sidebar; selecting it shows `SettingsView()` in the detail pane.

- [ ] **Step 3: Build + verify** — the main window has "Settings", the toggle changes
`config.json` (verify with `grep vmMemoryMonitoring ~/Library/Application\ Support/DevDeck/config.json`),
and the VM row in the popover appears/disappears accordingly.

Run: `xcodebuild build ...`; click "Settings", flip the toggle, check config.json and the popover.
Expected: toggle writes the flag, popover responds.

- [ ] **Step 4: Final full test run.**

Run: `xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'`
Expected: entire suite green.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/MainWindow/SettingsView.swift DevDeck/MainWindow/MainWindowView.swift
git commit -m "UI: Settings pane with VM memory monitoring toggle"
```

---

## Self-Review (completed during authoring)

- **Spec coverage:** flag (T1,T6,T8) · model/format/limit (T2) · footprint (T3) · probe (T4) ·
  live row (T7) · peak+hint+sampler (T5) · Settings (T8). All spec sections covered.
- **Placeholders:** code is provided at every step; integration steps (sidebar, save()) reference
  SPECIFIC existing patterns in the same file (Command-decode, upsert, swap row) — no "TODO".
- **Type consistency:** `VMMemoryInfo`, `VMMemoryProbing.sample()`, `vmMemorySample()`,
  `recordVMSample(for:)`, `vmPeakBytes(for:)`, `isVMMonitoringEnabled`, `setVMMonitoring(_:)`,
  `Config.settings.vmMemoryMonitoring` — names are consistent across all tasks.
- **Out of scope:** minikube Tier 2, CPU, exact numeric recommendations — not in this plan (per spec).
