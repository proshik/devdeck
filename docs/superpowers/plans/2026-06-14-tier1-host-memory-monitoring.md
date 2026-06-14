# Tier 1 — Host Memory Monitoring Implementation Plan

> **STATUS: ✅ COMPLETED 2026-06-14** on branch `feat/tier1-host-memory` (Tasks 1–9 + a post-smoke
> badge fix). Full suite green (167 tests). Deferred follow-ups (tracked, not blockers): live
> swap-rate display in the UI (pure `swapRatePagesPerSec` done) and live colima cpus/limit in the
> `-j` advisory (currently fixed defaults). See `docs/PLAN.md` Status / Tier 1 for the roadmap view.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add cheap, host-side memory signals so heavy Rust builds (running behind nested colima→minikube→pod limits) can be diagnosed and right-sized — predict thrashing, catch OOM, and record per-build peaks — without entering the VM.

**Architecture:** A new `HostMetricsProbing` protocol (mirrors the existing `VMMemoryProbing`) wraps the kernel reads (`sysctl` pressure level, `HOST_VM_INFO64` swap/compressor counters, `ProcessTree.physFootprint` of the build PID) so `ProcessManager` and the sampler are testable with a fake. All math/parsing/formatting lives in **pure functions** unit-tested without the kernel. The existing 1 Hz sampler loop and `flushRunPeaks` are extended to accumulate host peaks and write a per-run summary to the log. Live metrics surface in the popover memory header; memory pressure tints a badge on the menu bar icon; OOM/crate detection and the `-j` advisory go to the log and the command editor. All new user-facing strings go through the `L10n` catalog (EN/RU). A new `Config.settings.hostMemoryMonitoring` flag (default `true`) gates it, mirroring `vmMemoryMonitoring`.

**Tech Stack:** Swift, SwiftUI + AppKit, Darwin (`sysctlbyname`, `host_statistics64`), XCTest. macOS 15+.

---

## File Structure

**New files:**
- `DevDeck/Diagnostics/HostMetrics.swift` — `MemoryPressureLevel` enum, `HostMetricsSample` struct (pure math: pressure, swap counters, compressor), `HostMetricsProbing` protocol + `LiveHostMetricsProbe` (kernel reads), `HostMetricsRunStats` (per-run accumulator), pure `swapRatePagesPerSec(...)`.
- `DevDeck/Diagnostics/BuildDiagnostics.swift` — pure parsers: `OOMVerdict` (`detectOOM(exitCode:logTail:)` → isOOM + crate name) and `BuildJobsAdvice` (`adviseJobs(command:env:vmCpus:limitBytes:)`).
- `DevDeckTests/HostMetricsTests.swift`, `DevDeckTests/BuildDiagnosticsTests.swift`, `DevDeckTests/Support/FakeHostMetricsProbe.swift`, `DevDeckTests/ProcessManagerHostMemoryTests.swift`.

**Modified files:**
- `DevDeck/Models/Config.swift` — add `Settings.hostMemoryMonitoring` (default `true`).
- `DevDeck/Store/CommandStore.swift` — add `setHostMonitoring(_:)`.
- `DevDeck/Diagnostics/VMMemory.swift` — add `VMMemoryInfo.parseColimaCpus(_:)` (cpus for the `-j` rule).
- `DevDeck/Process/ProcessManager.swift` — capture build PID on `.started`; host sampler + `hostPeak`/`hostStats`; extend `flushRunPeaks` with a host summary; OOM/crate detection on terminate.
- `DevDeck/MenuBar/TrayIcon.swift` — `image(pressureColor:)` optional badge.
- `DevDeck/MenuBar/MenuBarController.swift` — refresh the tray icon from a pressure source.
- `DevDeck/MenuBar/PopoverView.swift` — live host lines (pressure text, swap rate, compressor %).
- `DevDeck/MainWindow/CommandEditorView.swift` — `-j` advisory caption.
- `DevDeck/MainWindow/SettingsView.swift` — host-monitoring toggle.
- `DevDeck/Localization/L10n.swift` — new EN/RU strings.

**Note on UI placement (deviation from `PLAN.md`):** `PLAN.md` said swap-rate/compressor/`-j` go to "main window". This plan puts the live host metrics in the **popover memory header** (the existing always-visible memory surface) and the `-j` advisory in the **command editor** (contextual to the command). Pressure → menu bar icon badge as specified. Peak/OOM/crate → log as specified. The plan reviewer can flip these placements; the testable cores are placement-independent.

---

## Task 1: HostMetricsSample + LiveHostMetricsProbe (foundation)

**Files:**
- Create: `DevDeck/Diagnostics/HostMetrics.swift`
- Test: `DevDeckTests/HostMetricsTests.swift`

- [ ] **Step 1: Write the failing test** (pure math only — no kernel)

In `DevDeckTests/HostMetricsTests.swift`:

```swift
import XCTest
@testable import DevDeck

final class HostMetricsTests: XCTestCase {
    func testPressureLevelFromRaw() {
        XCTAssertEqual(MemoryPressureLevel(raw: 1), .normal)
        XCTAssertEqual(MemoryPressureLevel(raw: 2), .warning)
        XCTAssertEqual(MemoryPressureLevel(raw: 4), .critical)
        XCTAssertEqual(MemoryPressureLevel(raw: 0), .normal)   // unknown → normal
    }

    func testSwapRateIsDeltaOverTime() {
        // 8192 page-ins over 2s = 4096 pages/sec; clamps negatives (counter reset) to 0.
        let rate = swapRatePagesPerSec(prevIn: 1000, prevOut: 500,
                                       curIn: 1000 + 8192, curOut: 500,
                                       dtSeconds: 2)
        XCTAssertEqual(rate.inPerSec, 4096, accuracy: 0.5)
        XCTAssertEqual(rate.outPerSec, 0, accuracy: 0.5)
        let reset = swapRatePagesPerSec(prevIn: 10_000, prevOut: 0, curIn: 5, curOut: 0, dtSeconds: 1)
        XCTAssertEqual(reset.inPerSec, 0, "counter reset must not produce a negative rate")
    }

    func testCompressorFractionAndFormat() {
        let s = HostMetricsSample(pressure: .warning, swapInsPages: 0, swapOutsPages: 0,
                                  compressorPages: 262_144, totalBytes: 16 * 1_073_741_824,
                                  buildFootprintBytes: 0)
        // 262144 pages * 16KiB? page size is 16384 on Apple Silicon → 4 GiB compressed.
        XCTAssertEqual(s.compressorBytes(pageSize: 16384), 4 * 1_073_741_824)
        XCTAssertEqual(HostMetricsSample.formatRate(pagesPerSec: 4096, pageSize: 16384), "64.0 MB/s")
        XCTAssertEqual(HostMetricsSample.formatRate(pagesPerSec: 0, pageSize: 16384), "0 MB/s")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/HostMetricsTests`
Expected: FAIL — `MemoryPressureLevel` / `swapRatePagesPerSec` / `HostMetricsSample` not found.

- [ ] **Step 3: Write the implementation**

Create `DevDeck/Diagnostics/HostMetrics.swift`:

```swift
import Foundation
import Darwin

/// Kernel verdict on memory shortage (`kern.memorystatus_vm_pressure_level`).
enum MemoryPressureLevel: Int, Equatable {
    case normal = 1
    case warning = 2
    case critical = 4

    init(raw: Int32) { self = MemoryPressureLevel(rawValue: Int(raw)) ?? .normal }
}

/// Pages/sec swap rate from two cumulative counter samples. Negative deltas
/// (counter reset / reboot) clamp to 0.
func swapRatePagesPerSec(prevIn: UInt64, prevOut: UInt64,
                         curIn: UInt64, curOut: UInt64,
                         dtSeconds: Double) -> (inPerSec: Double, outPerSec: Double) {
    guard dtSeconds > 0 else { return (0, 0) }
    let dIn = curIn >= prevIn ? Double(curIn - prevIn) : 0
    let dOut = curOut >= prevOut ? Double(curOut - prevOut) : 0
    return (dIn / dtSeconds, dOut / dtSeconds)
}

/// A host-side memory snapshot beyond what `SystemMemory` exposes.
struct HostMetricsSample: Equatable {
    let pressure: MemoryPressureLevel
    let swapInsPages: UInt64       // cumulative since boot
    let swapOutsPages: UInt64      // cumulative since boot
    let compressorPages: UInt64
    let totalBytes: UInt64
    let buildFootprintBytes: UInt64   // RSS footprint of the tracked build PID (0 if none)

    func compressorBytes(pageSize: UInt64) -> UInt64 { compressorPages * pageSize }
    func compressorFraction(pageSize: UInt64) -> Double {
        totalBytes > 0 ? Double(compressorBytes(pageSize: pageSize)) / Double(totalBytes) : 0
    }

    /// "64.0 MB/s" — binary MiB/s, or "0 MB/s" when idle. A pure function.
    static func formatRate(pagesPerSec: Double, pageSize: UInt64) -> String {
        let bytesPerSec = pagesPerSec * Double(pageSize)
        if bytesPerSec < 1 { return "0 MB/s" }
        return String(format: "%.1f MB/s", bytesPerSec / 1_048_576.0)
    }
}

/// Behind a protocol → ProcessManager/popover are tested with a fake (no kernel reads).
protocol HostMetricsProbing: Sendable {
    /// `buildPID` — footprint that PID (the running build), or nil to skip it.
    func sample(buildPID: Int32?) -> HostMetricsSample
}

/// Real probe: sysctl pressure level + HOST_VM_INFO64 swap/compressor counters + PID footprint.
struct LiveHostMetricsProbe: HostMetricsProbing {
    func sample(buildPID: Int32?) -> HostMetricsSample {
        let total = ProcessInfo.processInfo.physicalMemory

        var level: Int32 = 1
        var size = MemoryLayout<Int32>.size
        _ = sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0)

        var stats = vm_statistics64_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &stats) { p in
            p.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        } == KERN_SUCCESS

        let footprint = buildPID.map { ProcessTree.physFootprint($0) } ?? 0
        return HostMetricsSample(
            pressure: MemoryPressureLevel(raw: level),
            swapInsPages: ok ? UInt64(stats.swapins) : 0,
            swapOutsPages: ok ? UInt64(stats.swapouts) : 0,
            compressorPages: ok ? UInt64(stats.compressor_page_count) : 0,
            totalBytes: total,
            buildFootprintBytes: footprint)
    }
}

/// Page size for rate/compressor conversions (16 KiB on Apple Silicon, 4 KiB on Intel).
let hostPageSize = UInt64(vm_page_size)
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/HostMetricsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Diagnostics/HostMetrics.swift DevDeckTests/HostMetricsTests.swift
git commit -m "feat(memory): HostMetricsSample + LiveHostMetricsProbe (pressure/swap/compressor) + pure math"
```

---

## Task 2: [P5] Memory pressure → menu bar icon badge

**Files:**
- Modify: `DevDeck/MenuBar/TrayIcon.swift`
- Test: `DevDeckTests/HostMetricsTests.swift` (extend)

- [ ] **Step 1: Write the failing test** (pure level→color mapping)

Append to `HostMetricsTests`:

```swift
func testPressureBadgeColor() {
    XCTAssertNil(TrayIcon.badgeColor(for: .normal), "no badge under normal pressure")
    XCTAssertEqual(TrayIcon.badgeColor(for: .warning), NSColor.systemYellow)
    XCTAssertEqual(TrayIcon.badgeColor(for: .critical), NSColor.systemRed)
}
```

Add `import AppKit` at the top of the test file (alongside `import XCTest`).

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:DevDeckTests/HostMetricsTests/testPressureBadgeColor`
Expected: FAIL — `TrayIcon.badgeColor` not found.

- [ ] **Step 3: Write the implementation**

In `DevDeck/MenuBar/TrayIcon.swift`, add inside `enum TrayIcon`:

```swift
/// Badge color for a pressure level; nil under normal pressure (no badge).
static func badgeColor(for level: MemoryPressureLevel) -> NSColor? {
    switch level {
    case .normal: return nil
    case .warning: return .systemYellow
    case .critical: return .systemRed
    }
}

/// The tray glyph, optionally with a colored pressure dot in the top-right corner.
/// With a badge the image is non-template (the dot keeps its color); the glyph is drawn
/// in `labelColor` so it still adapts to the menu bar appearance.
static func image(pressureColor: NSColor?) -> NSImage {
    guard let pressureColor else { return image() }   // normal → existing template glyph
    let base = image()
    let composed = NSImage(size: base.size, flipped: false) { rect in
        NSColor.labelColor.set()
        base.draw(in: rect)   // template glyph tinted with the current label color
        let d: CGFloat = 6
        let dot = NSRect(x: rect.maxX - d, y: rect.maxY - d, width: d, height: d)
        pressureColor.setFill()
        NSBezierPath(ovalIn: dot).fill()
        return true
    }
    composed.isTemplate = false
    return composed
}
```

> Note: drawing a template image tinted by `labelColor` is the pragmatic way to keep the glyph readable in both light/dark menu bars while showing a colored dot. This is the only visually fiddly step — verify it manually in Task 9.

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:DevDeckTests/HostMetricsTests/testPressureBadgeColor`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/MenuBar/TrayIcon.swift DevDeckTests/HostMetricsTests.swift
git commit -m "feat(memory): tray icon pressure badge (warning=yellow, critical=red)"
```

---

## Task 3: Config flag + FakeHostMetricsProbe + host sampler in ProcessManager

This wires the probe into `ProcessManager`, captures the build PID, accumulates a per-run host peak, and gates it on a new flag — mirroring the existing VM sampler exactly.

**Files:**
- Modify: `DevDeck/Models/Config.swift`, `DevDeck/Store/CommandStore.swift`, `DevDeck/Process/ProcessManager.swift`
- Create: `DevDeckTests/Support/FakeHostMetricsProbe.swift`, `DevDeckTests/ProcessManagerHostMemoryTests.swift`

- [ ] **Step 1: Add the config flag**

In `DevDeck/Models/Config.swift`, extend `Settings`:

```swift
struct Settings: Codable, Equatable {
    var vmMemoryMonitoring: Bool
    var minikubeMemoryMonitoring: Bool
    var hostMemoryMonitoring: Bool

    init(vmMemoryMonitoring: Bool = true, minikubeMemoryMonitoring: Bool = true,
         hostMemoryMonitoring: Bool = true) {
        self.vmMemoryMonitoring = vmMemoryMonitoring
        self.minikubeMemoryMonitoring = minikubeMemoryMonitoring
        self.hostMemoryMonitoring = hostMemoryMonitoring
    }

    enum CodingKeys: String, CodingKey {
        case vmMemoryMonitoring, minikubeMemoryMonitoring, hostMemoryMonitoring
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        vmMemoryMonitoring = try c.decodeIfPresent(Bool.self, forKey: .vmMemoryMonitoring) ?? true
        minikubeMemoryMonitoring = try c.decodeIfPresent(Bool.self, forKey: .minikubeMemoryMonitoring) ?? true
        hostMemoryMonitoring = try c.decodeIfPresent(Bool.self, forKey: .hostMemoryMonitoring) ?? true
    }
}
```

- [ ] **Step 2: Add the store mutator**

In `DevDeck/Store/CommandStore.swift`, after `setMinikubeMonitoring`:

```swift
func setHostMonitoring(_ on: Bool) {
    guard config.settings.hostMemoryMonitoring != on else { return }
    var updated = config
    updated.settings.hostMemoryMonitoring = on
    persist(updated)
}
```

- [ ] **Step 3: Write the fake probe**

Create `DevDeckTests/Support/FakeHostMetricsProbe.swift`:

```swift
import Foundation
@testable import DevDeck

/// Returns scripted samples in order, repeating the last one once exhausted.
final class FakeHostMetricsProbe: HostMetricsProbing, @unchecked Sendable {
    private let samples: [HostMetricsSample]
    private var index = 0
    private(set) var lastBuildPID: Int32?

    init(_ samples: [HostMetricsSample]) { self.samples = samples }

    func sample(buildPID: Int32?) -> HostMetricsSample {
        lastBuildPID = buildPID
        defer { if index < samples.count - 1 { index += 1 } }
        return samples.isEmpty
            ? HostMetricsSample(pressure: .normal, swapInsPages: 0, swapOutsPages: 0,
                                compressorPages: 0, totalBytes: 16 * 1_073_741_824, buildFootprintBytes: 0)
            : samples[min(index, samples.count - 1)]
    }
}
```

- [ ] **Step 4: Write the failing test**

Create `DevDeckTests/ProcessManagerHostMemoryTests.swift`:

```swift
import XCTest
@testable import DevDeck

@MainActor
final class ProcessManagerHostMemoryTests: XCTestCase {
    private func cmd() -> Command { Command(id: UUID(), name: "build", command: "just dev-build") }

    func testHostFootprintPeakAccumulatesAndClearsOnTerminate() async {
        let gib: UInt64 = 1_073_741_824
        let probe = FakeHostMetricsProbe([
            HostMetricsSample(pressure: .normal, swapInsPages: 0, swapOutsPages: 0,
                              compressorPages: 0, totalBytes: 16 * gib, buildFootprintBytes: 3 * gib),
            HostMetricsSample(pressure: .warning, swapInsPages: 0, swapOutsPages: 0,
                              compressorPages: 0, totalBytes: 16 * gib, buildFootprintBytes: 7 * gib),
            HostMetricsSample(pressure: .normal, swapInsPages: 0, swapOutsPages: 0,
                              compressorPages: 0, totalBytes: 16 * gib, buildFootprintBytes: 5 * gib),
        ])
        let fake = FakeCommandRunner()
        let m = ProcessManager(runner: fake, hostProbe: probe, hostMonitoringEnabled: { true })
        let c = cmd()
        fake.eagerScripts[c.id] = [.started(pid: 99)]
        m.run(c)
        let ctrl = try! XCTUnwrap(fake.controller(for: c.id))
        await yieldUntil { m.states[c.id] == .running }

        m.recordHostSample(for: c.id)   // footprint 3 GiB
        m.recordHostSample(for: c.id)   // footprint 7 GiB (peak)
        m.recordHostSample(for: c.id)   // footprint 5 GiB
        XCTAssertEqual(m.hostPeakFootprint(for: c.id), 7 * gib)
        XCTAssertEqual(probe.lastBuildPID, 99, "the captured .started PID is footprinted")

        ctrl.terminate(0)
        await yieldUntil { m.states[c.id] == .succeeded }
        XCTAssertNil(m.hostPeakFootprint(for: c.id), "host peak is cleared on termination")
    }

    func testDisabledFlagSkipsHostSampling() {
        let m = ProcessManager(runner: FakeCommandRunner(),
                               hostProbe: FakeHostMetricsProbe([]), hostMonitoringEnabled: { false })
        let id = UUID()
        m.recordHostSample(for: id)
        XCTAssertNil(m.hostPeakFootprint(for: id))
    }
}
```

- [ ] **Step 5: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:DevDeckTests/ProcessManagerHostMemoryTests`
Expected: FAIL — `ProcessManager` has no `hostProbe:`/`hostMonitoringEnabled:` init params, `recordHostSample`, `hostPeakFootprint`.

- [ ] **Step 6: Wire the host probe into ProcessManager**

In `DevDeck/Process/ProcessManager.swift`:

a) Add stored properties after the minikube sampler block (near line 86):

```swift
    // MARK: host sampler (Tier 1)
    @ObservationIgnored private let hostProbe: any HostMetricsProbing
    @ObservationIgnored var isHostMonitoringEnabled: () -> Bool
    @ObservationIgnored private var hostPeak: [UUID: UInt64] = [:]       // build footprint peak per run
    @ObservationIgnored private var hostStats: [UUID: HostMetricsSample] = [:]  // last sample (for pressure/swap peak)
    @ObservationIgnored private var buildPIDs: [UUID: Int32] = [:]       // PID captured from .started
    /// Last host snapshot for the popover (live), updated by the sampler.
    private(set) var cachedHostSample: HostMetricsSample?
```

b) Add to `init(...)` parameters (after `minikubeMonitoringEnabled`):

```swift
        hostProbe: any HostMetricsProbing = LiveHostMetricsProbe(),
        hostMonitoringEnabled: @escaping () -> Bool = { true }
```

and in the body:

```swift
        self.hostProbe = hostProbe
        self.isHostMonitoringEnabled = hostMonitoringEnabled
```

c) Capture the PID in `apply(...)`, in `case .started:` (before `startVMSamplerIfNeeded()`):

```swift
            if let pid = pidFromStart(token: token) { buildPIDs[commandID] = pid }
```

Since `apply` doesn't currently receive the pid, change the consumer to pass it. Simplest: capture from the event. Replace the `.started` case head with binding:

```swift
        case .started(let pid):
            if let pid { buildPIDs[commandID] = pid }
            if isDaemon { ... }   // existing body unchanged
            startVMSamplerIfNeeded()
```

(Delete the `pidFromStart` helper idea above — bind `pid` directly from `.started(let pid)`.)

d) Add the public test/sampler hooks (after `vmPeakBytes`):

```swift
    /// One host sample for run id (called from tests). Synchronous.
    func recordHostSample(for id: UUID) {
        guard isHostMonitoringEnabled() else { return }
        let s = hostProbe.sample(buildPID: buildPIDs[id])
        accumulateHostPeak(s, for: id)
    }

    func hostPeakFootprint(for id: UUID) -> UInt64? { hostPeak[id] }

    private func accumulateHostPeak(_ s: HostMetricsSample, for id: UUID) {
        hostStats[id] = s
        if s.buildFootprintBytes > (hostPeak[id] ?? 0) { hostPeak[id] = s.buildFootprintBytes }
    }
```

e) Clear on terminate: in `flushRunPeaks(_:name:)` add a call `flushHostStats(id, name: name)` and implement (see Task 5 for the log body — for now just clear):

```swift
    private func flushHostStats(_ id: UUID, name: String) {
        hostPeak.removeValue(forKey: id)
        hostStats.removeValue(forKey: id)
        buildPIDs.removeValue(forKey: id)
    }
```

f) Sample host in the existing sampler loop. In `startVMSamplerIfNeeded()`'s loop, after the minikube block, add (gated):

```swift
                if self.isHostMonitoringEnabled() {
                    let buildPIDs = self.buildPIDs
                    let hostProbe = self.hostProbe
                    let host = await Task.detached(priority: .utility) {
                        // sample the first active build PID (single heavy build is the norm)
                        hostProbe.sample(buildPID: buildPIDs.values.first)
                    }.value
                    self.cachedHostSample = host
                    for id in self.active.keys { self.accumulateHostPeak(host, for: id) }
                }
```

Also widen the sampler's start guard to include the host flag:

```swift
        guard vmSamplerTask == nil,
              isVMMonitoringEnabled() || isMinikubeMonitoringEnabled() || isHostMonitoringEnabled() else { return }
```

and clear `cachedHostSample = nil` next to `cachedMinikubeSample = nil` when the loop ends.

- [ ] **Step 7: Wire the flag in AppDelegate**

In `DevDeck/AppDelegate.swift`, after the minikube line:

```swift
        manager.isHostMonitoringEnabled = { [weak store] in store?.config.settings.hostMemoryMonitoring ?? false }
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `xcodebuild test ... -only-testing:DevDeckTests/ProcessManagerHostMemoryTests`
Expected: PASS (2 tests).

- [ ] **Step 9: Commit**

```bash
git add DevDeck/Models/Config.swift DevDeck/Store/CommandStore.swift DevDeck/Process/ProcessManager.swift DevDeck/AppDelegate.swift DevDeckTests/Support/FakeHostMetricsProbe.swift DevDeckTests/ProcessManagerHostMemoryTests.swift
git commit -m "feat(memory): host sampler in ProcessManager (build-PID footprint peak, hostMemoryMonitoring flag)"
```

---

## Task 4: [P4] Peak + [P5] swap + pressure summary → log on terminate

**Files:**
- Modify: `DevDeck/Process/ProcessManager.swift`
- Test: `DevDeckTests/ProcessManagerHostMemoryTests.swift` (extend)

- [ ] **Step 1: Write the failing test**

Append to `ProcessManagerHostMemoryTests`. Assert via a captured log — add a tiny log sink. Since `DiagnosticLog.shared` writes to a temp file under XCTest, read it:

```swift
    func testTerminateWritesHostSummaryToLog() async throws {
        let gib: UInt64 = 1_073_741_824
        let probe = FakeHostMetricsProbe([
            HostMetricsSample(pressure: .warning, swapInsPages: 0, swapOutsPages: 0,
                              compressorPages: 0, totalBytes: 16 * gib, buildFootprintBytes: 6 * gib),
        ])
        let fake = FakeCommandRunner()
        let m = ProcessManager(runner: fake, hostProbe: probe, hostMonitoringEnabled: { true })
        let c = Command(id: UUID(), name: "heavy-build", command: "just dev-build")
        fake.eagerScripts[c.id] = [.started(pid: 7)]
        m.run(c)
        let ctrl = try XCTUnwrap(fake.controller(for: c.id))
        await yieldUntil { m.states[c.id] == .running }
        m.recordHostSample(for: c.id)

        let before = (try? String(contentsOf: DiagnosticLog.shared.fileURL, encoding: .utf8)) ?? ""
        ctrl.terminate(0)
        await yieldUntil { m.states[c.id] == .succeeded }
        let after = try String(contentsOf: DiagnosticLog.shared.fileURL, encoding: .utf8)
        let added = String(after.dropFirst(before.count))
        XCTAssertTrue(added.contains("Host peak for “heavy-build”"), added)
        XCTAssertTrue(added.contains("6.0 GB"), "build footprint peak in the summary: \(added)")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:DevDeckTests/ProcessManagerHostMemoryTests/testTerminateWritesHostSummaryToLog`
Expected: FAIL — no "Host peak" line written.

- [ ] **Step 3: Implement the summary in `flushHostStats`**

Replace the Task 3 stub `flushHostStats` body with:

```swift
    private func flushHostStats(_ id: UUID, name: String) {
        defer { hostPeak.removeValue(forKey: id); hostStats.removeValue(forKey: id); buildPIDs.removeValue(forKey: id) }
        guard let peak = hostPeak[id], peak > 0 else { return }
        let last = hostStats[id]
        let peakGB = String(format: "%.1f GB", Double(peak) / 1_073_741_824.0)
        var line = "Host peak for “\(name)”: build RSS \(peakGB)"
        if let last {
            let pressure: String
            switch last.pressure {
            case .normal: pressure = "normal"
            case .warning: pressure = "warning"
            case .critical: pressure = "critical"
            }
            line += " · pressure \(pressure)"
            let compFrac = Int((last.compressorFraction(pageSize: hostPageSize) * 100).rounded())
            if compFrac > 0 { line += " · compressor \(compFrac)%" }
        }
        DiagnosticLog.shared.log(line, level: last?.pressure == .critical ? .warn : .info)
    }
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:DevDeckTests/ProcessManagerHostMemoryTests/testTerminateWritesHostSummaryToLog`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Process/ProcessManager.swift DevDeckTests/ProcessManagerHostMemoryTests.swift
git commit -m "feat(memory): per-run host summary to log (build peak RSS + pressure + compressor)"
```

---

## Task 5: [P5] OOM / non-zero exit + crate name detection

**Files:**
- Create: `DevDeck/Diagnostics/BuildDiagnostics.swift`, `DevDeckTests/BuildDiagnosticsTests.swift`
- Modify: `DevDeck/Process/ProcessManager.swift`

- [ ] **Step 1: Write the failing test** (pure parser)

Create `DevDeckTests/BuildDiagnosticsTests.swift`:

```swift
import XCTest
@testable import DevDeck

final class BuildDiagnosticsTests: XCTestCase {
    func testDetectsSignal9AsOOM() {
        let v = detectOOM(exitCode: 137, logTail: "")   // 128 + 9
        XCTAssertTrue(v.isOOM)
        let v2 = detectOOM(exitCode: 9, logTail: "")
        XCTAssertTrue(v2.isOOM)
        XCTAssertFalse(detectOOM(exitCode: 1, logTail: "error[E0277]").isOOM)
        XCTAssertFalse(detectOOM(exitCode: 0, logTail: "").isOOM)
    }

    func testExtractsCrateFromCouldNotCompile() {
        let tail = """
        error: could not compile `solana-runtime` (lib) due to 1 previous error
        """
        XCTAssertEqual(detectOOM(exitCode: 101, logTail: tail).crate, "solana-runtime")
    }

    func testOOMFromLogTextEvenWithGenericExit() {
        let tail = "rustc killed (signal: 9, SIGKILL: 9)\nerror: could not compile `heavy-crate`"
        let v = detectOOM(exitCode: 101, logTail: tail)
        XCTAssertTrue(v.isOOM, "signal: 9 in the log marks OOM even when the wrapper exit is 101")
        XCTAssertEqual(v.crate, "heavy-crate")
    }

    func testNoCrateNoFalsePositive() {
        let v = detectOOM(exitCode: 1, logTail: "warning: unused variable")
        XCTAssertFalse(v.isOOM)
        XCTAssertNil(v.crate)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `xcodebuild test ... -only-testing:DevDeckTests/BuildDiagnosticsTests`
Expected: FAIL — `detectOOM` not found.

- [ ] **Step 3: Write the implementation**

Create `DevDeck/Diagnostics/BuildDiagnostics.swift`:

```swift
import Foundation

struct OOMVerdict: Equatable {
    let isOOM: Bool
    let crate: String?
}

/// Detects an OOM/SIGKILL build failure and the offending crate.
/// - OOM if the exit code is 9 or 137 (128+SIGKILL), or the log tail contains "signal: 9".
/// - The crate is parsed from rustc's ``error: could not compile `NAME` `` line.
func detectOOM(exitCode: Int32, logTail: String) -> OOMVerdict {
    let isOOM = exitCode == 9 || exitCode == 137 || logTail.contains("signal: 9")
    var crate: String?
    if let range = logTail.range(of: #"could not compile `([^`]+)`"#, options: .regularExpression) {
        let match = String(logTail[range])
        if let inner = match.range(of: #"`([^`]+)`"#, options: .regularExpression) {
            crate = String(match[inner]).trimmingCharacters(in: CharacterSet(charactersIn: "`"))
        }
    }
    return OOMVerdict(isOOM: isOOM, crate: crate)
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `xcodebuild test ... -only-testing:DevDeckTests/BuildDiagnosticsTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Wire detection into ProcessManager terminate**

In `apply(...)`, `case .terminated(let code):`, in the `else` branch where `code != 0` (after the existing `scanOOMIfNeeded`), add host-side detection from the run's own log buffer:

```swift
                if code != 0, isHostMonitoringEnabled() {
                    let tail = logs[commandID]?.elements.suffix(40).map(\.text).joined(separator: "\n") ?? ""
                    let verdict = detectOOM(exitCode: code, logTail: tail)
                    if verdict.isOOM {
                        let crate = verdict.crate.map { " · crate `\($0)`" } ?? ""
                        DiagnosticLog.shared.log("Likely OOM: \(tag) (signal 9 / SIGKILL)\(crate)", level: .warn)
                    } else if let c = verdict.crate {
                        DiagnosticLog.shared.log("Build failed at crate `\(c)`: \(tag)", level: .warn)
                    }
                }
```

(Do the same in `applyChainTerminal(...)`'s `else` branch for chains-in-terminal.)

- [ ] **Step 6: Run the full suite to verify nothing regressed**

Run: `xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'`
Expected: PASS (all tests).

- [ ] **Step 7: Commit**

```bash
git add DevDeck/Diagnostics/BuildDiagnostics.swift DevDeckTests/BuildDiagnosticsTests.swift DevDeck/Process/ProcessManager.swift
git commit -m "feat(memory): OOM/SIGKILL detection + offending crate name to log"
```

---

## Task 6: [P3] Effective -j vs RAM limit advisory

**Files:**
- Modify: `DevDeck/Diagnostics/BuildDiagnostics.swift`, `DevDeck/Diagnostics/VMMemory.swift`
- Test: `DevDeckTests/BuildDiagnosticsTests.swift` (extend), `DevDeckTests/VMMemoryTests.swift` (extend)

- [ ] **Step 1: Write the failing tests**

Append to `BuildDiagnosticsTests`:

```swift
func testAdviseJobsAppliesLimitOverTwoRule() {
    let gib: UInt64 = 1_073_741_824
    // limit 6 GiB → ~3 safe rustc; default -j = 6 cores → over budget.
    let a = adviseJobs(command: "just dev-build", env: [:], vmCpus: 6, limitBytes: 6 * gib)
    XCTAssertEqual(a.effectiveJobs, 6, "default -j = VM cores")
    XCTAssertEqual(a.advisedJobs, 3, "limit_GB / 2")
    XCTAssertTrue(a.overBudget)
}

func testAdviseJobsReadsExplicitFlagAndEnv() {
    let gib: UInt64 = 1_073_741_824
    XCTAssertEqual(adviseJobs(command: "cargo build -j 2", env: [:], vmCpus: 6, limitBytes: 6 * gib).effectiveJobs, 2)
    XCTAssertEqual(adviseJobs(command: "just x", env: ["CARGO_BUILD_JOBS": "4"], vmCpus: 6, limitBytes: 6 * gib).effectiveJobs, 4)
    let ok = adviseJobs(command: "cargo build -j 3", env: [:], vmCpus: 6, limitBytes: 6 * gib)
    XCTAssertFalse(ok.overBudget, "3 jobs fit within 6 GiB")
}
```

Append to `VMMemoryTests`:

```swift
func testParseColimaCpus() {
    let json = #"{"name":"default","status":"Running","memory":10737418240,"cpus":6}"#
    XCTAssertEqual(VMMemoryInfo.parseColimaCpus(json), 6)
    XCTAssertNil(VMMemoryInfo.parseColimaCpus("not json"))
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `xcodebuild test ... -only-testing:DevDeckTests/BuildDiagnosticsTests -only-testing:DevDeckTests/VMMemoryTests`
Expected: FAIL — `adviseJobs` / `parseColimaCpus` not found.

- [ ] **Step 3: Implement `parseColimaCpus`**

In `DevDeck/Diagnostics/VMMemory.swift`, alongside `parseColimaLimitBytes`:

```swift
/// CPU count from `colima list --json` (`cpus`). nil on failure.
static func parseColimaCpus(_ json: String) -> Int? {
    guard let data = json.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let cpus = obj["cpus"] as? NSNumber else { return nil }
    let v = cpus.intValue
    return v > 0 ? v : nil
}
```

- [ ] **Step 4: Implement `adviseJobs`**

In `DevDeck/Diagnostics/BuildDiagnostics.swift`:

```swift
struct BuildJobsAdvice: Equatable {
    let effectiveJobs: Int   // what the build will actually use
    let advisedJobs: Int     // safe max for the RAM limit (limit_GB / 2, min 1)
    var overBudget: Bool { effectiveJobs > advisedJobs }
}

/// Reconcile build parallelism with the VM RAM limit.
/// Rule of thumb: ~2 GiB per concurrent rustc → safe jobs = limit_GB / 2.
/// Effective jobs: explicit `-j N` in the command > `CARGO_BUILD_JOBS` env > VM core count.
func adviseJobs(command: String, env: [String: String], vmCpus: Int, limitBytes: UInt64) -> BuildJobsAdvice {
    var effective = max(1, vmCpus)
    if let envJobs = env["CARGO_BUILD_JOBS"].flatMap(Int.init), envJobs > 0 { effective = envJobs }
    if let range = command.range(of: #"-j\s*([0-9]+)"#, options: .regularExpression) {
        let digits = command[range].filter(\.isNumber)
        if let n = Int(digits), n > 0 { effective = n }
    }
    let limitGB = Double(limitBytes) / 1_073_741_824.0
    let advised = max(1, Int(limitGB / 2.0))
    return BuildJobsAdvice(effectiveJobs: effective, advisedJobs: advised)
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `xcodebuild test ... -only-testing:DevDeckTests/BuildDiagnosticsTests -only-testing:DevDeckTests/VMMemoryTests`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add DevDeck/Diagnostics/BuildDiagnostics.swift DevDeck/Diagnostics/VMMemory.swift DevDeckTests/BuildDiagnosticsTests.swift DevDeckTests/VMMemoryTests.swift
git commit -m "feat(memory): -j vs RAM-limit advisory (limit_GB/2 rule) + colima cpus parse"
```

---

## Task 7: i18n strings for the new UI

**Files:**
- Modify: `DevDeck/Localization/L10n.swift`

- [ ] **Step 1: Add the strings**

Append a new section to `enum L10n` in `DevDeck/Localization/L10n.swift`:

```swift
    // MARK: - Host memory monitoring (Tier 1)

    static var hostMonitoringToggle: String {
        t("Host memory: pressure, swap rate, build peak, OOM detection",
          "Память хоста: давление, swap-rate, пик сборки, OOM-детект")
    }
    static var pressureNormal: String { t("Pressure: normal", "Давление: норма") }
    static var pressureWarning: String { t("Pressure: warning", "Давление: тревога") }
    static var pressureCritical: String { t("Pressure: critical", "Давление: критично") }
    static var swapRate: String { t("Swap rate", "Swap-rate") }
    static var compressor: String { t("Compressor", "Компрессор") }
    static func jobsAdvice(_ effective: Int, _ advised: Int) -> String {
        t("Build uses \(effective) jobs; safe for this RAM limit: \(advised)",
          "Сборка: \(effective) задач; безопасно для лимита RAM: \(advised)")
    }
    static func jobsLabel(_ pressureKey: MemoryPressureLevel) -> String {
        switch pressureKey {
        case .normal: return pressureNormal
        case .warning: return pressureWarning
        case .critical: return pressureCritical
        }
    }
```

- [ ] **Step 2: Verify it compiles**

Run: `xcodebuild build -project DevDeck.xcodeproj -scheme DevDeck -configuration Debug -derivedDataPath build/dd`
Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Commit**

```bash
git add DevDeck/Localization/L10n.swift
git commit -m "i18n: EN/RU strings for host memory monitoring UI"
```

---

## Task 8: Surface live metrics in the popover + Settings toggle + editor advisory

These steps are UI wiring (no new unit tests; covered by the build + the manual check in Task 9). Each binds existing `ProcessManager`/`CommandStore` data through `L10n`.

**Files:**
- Modify: `DevDeck/MenuBar/PopoverView.swift`, `DevDeck/MainWindow/SettingsView.swift`, `DevDeck/MainWindow/CommandEditorView.swift`, `DevDeck/MenuBar/MenuBarController.swift`

- [ ] **Step 1: Settings toggle**

In `DevDeck/MainWindow/SettingsView.swift`, inside the `Section(L10n.memoryMonitoringSection)`, add a third toggle:

```swift
                Toggle(L10n.hostMonitoringToggle, isOn: Binding(
                    get: { store.config.settings.hostMemoryMonitoring },
                    set: { store.setHostMonitoring($0) }
                ))
```

- [ ] **Step 2: Popover live host lines**

In `DevDeck/MenuBar/PopoverView.swift` `memoryHeader`, after the `minikubeSample()` block, add:

```swift
                if let host = manager.cachedHostSample {
                    if host.pressure != .normal {
                        HStack {
                            Text(L10n.jobsLabel(host.pressure)).foregroundStyle(.secondary)
                            Spacer()
                        }.font(.system(size: 10))
                    }
                    let inRate = HostMetricsSample.formatRate(
                        pagesPerSec: Double(host.swapInsPages), pageSize: hostPageSize)
                    // swap rate needs two samples; show the compressor fraction (instantaneous).
                    let comp = Int((host.compressorFraction(pageSize: hostPageSize) * 100).rounded())
                    if comp > 0 {
                        HStack {
                            Text(L10n.compressor).foregroundStyle(.secondary)
                            Spacer()
                            Text("\(comp)%").monospacedDigit().foregroundStyle(.secondary)
                        }.font(.system(size: 10))
                    }
                    _ = inRate   // swap-rate display is added once the sampler tracks deltas (see note)
                }
```

> Note: the live swap **rate** needs the sampler to hold the previous sample + timestamp and call `swapRatePagesPerSec`. To keep this task UI-only, the popover shows pressure + compressor now; wire the rate delta into the sampler as the optional follow-up below. The pure `swapRatePagesPerSec` is already tested in Task 1.

- [ ] **Step 3: Build-jobs advisory in the command editor**

In `DevDeck/MainWindow/CommandEditorView.swift`, inside the `Section(L10n.commandSection)`, after the toggles, add a caption that appears when the command looks like a Rust build:

```swift
                if draft.command.contains("cargo") || draft.command.contains("dev-build") {
                    let advice = adviseJobs(command: draft.command, env: assembledDraft.env,
                                            vmCpus: 6, limitBytes: 6 * 1_073_741_824)
                    Text(L10n.jobsAdvice(advice.effectiveJobs, advice.advisedJobs))
                        .font(.caption)
                        .foregroundStyle(advice.overBudget ? .orange : .secondary)
                }
```

> `vmCpus: 6` / `limitBytes: 6 GiB` are sensible defaults matching `default-config`; wiring live colima values (`parseColimaCpus`/`parseColimaLimitBytes`) is the optional follow-up.

- [ ] **Step 4: Menu bar pressure badge refresh**

In `DevDeck/MenuBar/MenuBarController.swift`, store the manager and refresh the icon on a 2 s timer from `manager.cachedHostSample?.pressure`:

```swift
    private let manager: ProcessManager
    private var iconTimer: Timer?
```

In `init`, capture `self.manager = manager` (add the property assignment), and after setting the initial button image:

```swift
        iconTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let button = self.statusItem.button else { return }
                let color = TrayIcon.badgeColor(for: self.manager.cachedHostSample?.pressure ?? .normal)
                button.image = TrayIcon.image(pressureColor: color)
                button.image?.accessibilityDescription = "DevDeck"
            }
        }
```

- [ ] **Step 5: Verify it compiles**

Run: `xcodebuild build -project DevDeck.xcodeproj -scheme DevDeck -configuration Debug -derivedDataPath build/dd`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Commit**

```bash
git add DevDeck/MenuBar/PopoverView.swift DevDeck/MainWindow/SettingsView.swift DevDeck/MainWindow/CommandEditorView.swift DevDeck/MenuBar/MenuBarController.swift
git commit -m "feat(memory): surface host metrics (popover pressure/compressor, settings toggle, -j advisory, tray badge)"
```

---

## Task 9: Full suite, manual smoke check, CHANGELOG/PLAN update

**Files:**
- Modify: `CHANGELOG.md`, `docs/PLAN.md`

- [ ] **Step 1: Run the full test suite**

Run: `xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'`
Expected: `** TEST SUCCEEDED **`, 0 failures.

- [ ] **Step 2: Manual smoke check** (the visual bits not covered by unit tests)

```sh
xcodebuild build -project DevDeck.xcodeproj -scheme DevDeck -configuration Debug -derivedDataPath build/dd
open build/dd/Build/Products/Debug/DevDeck.app
```
Verify: Settings shows the host toggle; running a command shows the host sampler active; switching language flips the new strings; the tray icon glyph still renders (and shows a colored dot under simulated pressure — optionally force `MemoryPressureLevel.warning` temporarily to eyeball the badge).

- [ ] **Step 3: Update CHANGELOG and PLAN**

In `CHANGELOG.md` under `## [Unreleased]`, add an `### Added` entry summarizing Tier 1 (host pressure level + tray badge, build-process peak RSS to log, OOM/SIGKILL + crate detection, `-j` vs RAM advisory, host-monitoring toggle).
In `docs/PLAN.md`, flip the six Tier 1 checkboxes (lines 166, 168, 176, 178, 180, 182) from `- [ ]` to `- [x]` with the implementing detail, mirroring the existing done entries.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md docs/PLAN.md
git commit -m "docs: Tier 1 host memory monitoring done (CHANGELOG + PLAN)"
```

---

## Self-Review Notes

- **Spec coverage:** P5 pressure → Task 2 (+badge Task 8); P5 swap-rate → pure fn Task 1, surfaced partially Task 8 (rate-delta in sampler is the documented optional follow-up); P5 OOM+crate → Task 5; P4 peak→log → Tasks 3–4; P4 compressor → Tasks 1/4/8; P3 `-j` → Task 6 + editor Task 8. All six covered.
- **Type consistency:** `HostMetricsSample`, `HostMetricsProbing.sample(buildPID:)`, `recordHostSample`, `hostPeakFootprint`, `detectOOM`/`OOMVerdict`, `adviseJobs`/`BuildJobsAdvice`, `parseColimaCpus`, `TrayIcon.image(pressureColor:)`/`badgeColor(for:)`, `L10n.hostMonitoringToggle` — names are used identically across tasks.
- **Known follow-ups (explicitly deferred, not placeholders):** (a) live swap-rate delta in the sampler (pure fn already done/tested); (b) wiring live colima cpus/limit into the editor advisory (parser done/tested). Both are additive and safe to do after the core lands.
