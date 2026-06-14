# Design: VM Memory Monitoring — colima (first increment)

> Date: 2026-06-10. Status: approved in brainstorming, pending review.

## Goal and Context

The big goal is a **"right-sizing advisor"**: understand how optimal the launch parameters of
`colima start --memory/--cpus` and `minikube start --memory/--cpus` are, both in myproject build
mode and in normal working mode (a single agent namespace). We proceed **incrementally**:

1. **This increment — colima memory** (cheap on the host): hypervisor RSS vs colima limit, live
   and as a peak per build, showing "headroom" → answers "is colima `--memory` optimal".
2. Next (outside this increment): minikube memory (Tier 2, probe inside the VM), CPU for both
   layers, consolidated parameter recommendation.

**Increment boundary (honest):** hypervisor RSS shows only the **outer** colima layer
(limit 10 GiB). Build failures from OOM happen in the **inner** minikube cgroup (6 GiB) inside
colima — this is NOT visible at this layer and belongs to Tier 2. That is, this increment tunes
colima `--memory`, but NOT minikube `--memory` and NOT `--cpus`.

## Facts (verified on machine)

- colima VM memory is held by the process `com.apple.Virtualization.VirtualMachine` (vz XPC), `ppid==1`.
  Search: `pgrep -f com.apple.Virtualization.VirtualMachine` (if multiple vz VMs — take the one with the highest RSS).
- Limit — from the machine: `colima list --json` → `"memory": 10737418240` (bytes).
- Process RSS = VM footprint: `proc_pid_rusage(pid, RUSAGE_INFO_V2).ri_phys_footprint`
  (already wrapped in `LiveAppController.physFootprint` — extract into a shared util).

## Global Flag (in config.json)

- New field **`Config.settings: Settings`**, `Settings { vmMemoryMonitoring: Bool }`.
  Codable, backward-compatible (missing field → default). **Default — `true`** (feature on by default).
  The `Settings` struct is designed with room for future Tier 1 flags.
- Source of truth — **config.json**: editable by hand (FileWatcher will pick it up) and from UI.
- **UI toggle:** a **"Settings"** item in the main window sidebar with a switch; writes to
  `store` (new method `updateSettings`/`setVMMonitoring`), which saves config.json.

## Components

### 1. Model and provider — `VMMemory`
- `VMMemoryInfo: Equatable { usedBytes: UInt64, limitBytes: UInt64 }` + `fraction`,
  `format()` (binary GiB, like `SystemMemory.format`), `headroomFraction` (= 1 − fraction).
- `protocol VMMemoryProbing { func sample() -> VMMemoryInfo? }` (behind a protocol → tests on a fake).
- `final class LiveVMMemoryProbe: VMMemoryProbing` (class — to hold a cache):
  - PID via `pgrep -f com.apple.Virtualization.VirtualMachine` (multiple → highest RSS);
    **cached**, re-read only if the cached PID is dead/missing.
  - `used` = `physFootprint(cachedPID)` — cheap syscall, every tick.
  - `limit` = parsed `colima list --json → memory`; **cached** (limit doesn't change at runtime),
    read lazily once, retried on `nil`.
  - Per-tick `sample()` = `physFootprint(PID)` (no process spawning while PID/limit are cached).
  - Returns `nil` if the VM process is not found (colima not running) or colima CLI is missing.
  - Pure parts (format, fraction, JSON limit parsing) — tested separately.

### 2. Live row in the popover (working mode)
- In `PopoverView.memoryHeader`, alongside RAM/swap: `VM colima X.X / 10 GiB · NN%`.
- Colour by fraction (like `pressureColor`: green < 70%, yellow < 85%, otherwise red).
- Updated on the existing `TimelineView(.periodic 1s)` tick → `probe.sample()`.
- Shown **only if** `store.config.settings.vmMemoryMonitoring && sample() != nil`.
  No VM / disabled → no row.

### 3. Peak per run + hint (build mode)
- `VMMemorySampler` in `ProcessManager`: `Task` ~1 Hz, active **while ≥1 command is running**
  (starts on the first `.started`, stops when there are no active runs). Gated by `isVMMonitoringEnabled()`.
- On each tick: `probe.sample()`; updates `vmPeak: [UUID: VMMemoryInfo]` (max by `usedBytes`)
  for each active run.
- On `.terminated`/`.cancelled` of a command: if there is a peak — writes to `DiagnosticLog`:
  `VM peak for «<name>»: 6.8 / 10 GiB (headroom 32%)` + a light hint based on thresholds:
  - headroom > ~30% → "colima --memory can be lowered";
  - headroom < ~10% → "very tight — raise colima --memory".
  Then clears `vmPeak[id]`.
- The sampler flag is passed to `ProcessManager` via an injectable
  `isVMMonitoringEnabled: () -> Bool` (AppDelegate wires it from `store`); provider —
  `VMMemoryProbing` (default `LiveVMMemoryProbe`, tests — fake).

## Data Flow

```
LiveVMMemoryProbe.sample() ← pgrep(VM) + physFootprint(pid) + colima json (limit cache)
PopoverView tick (1s) ──► probe.sample() ──► live row (if flag)
VMMemorySampler tick (1s, while active) ──► sample().used ──► vmPeak[id] = max
ProcessManager.apply(.terminated) ──► log peak + hint, clear
```

## Error Handling / Edge Cases

- colima not running / VM process not found → `sample()==nil` → no row, no peak written.
- `colima` not in PATH → limit `nil` → `sample()` without limit → `nil` (don't show without limit).
- Multiple vz VMs (e.g. Docker Desktop) → take the process with the highest RSS.
- Flag disabled → neither row nor sampler (zero overhead).
- Multiple concurrent runs share VM-RSS — peak is written per run (correct for the common case of "one build at a time").

## Testing (TDD)

- `VMMemoryInfo`: `format`/`fraction`/`headroomFraction` on fixtures.
- Limit parsing from a `colima list --json` string (pure function).
- Peak sampler logic on a fake `VMMemoryProbing`: feed a sequence of `sample()` calls,
  verify `max` and that on termination a log line is written with the correct peak/headroom; flag off → no sampling.
- `LiveVMMemoryProbe` (pgrep/colima) — not run in the automated suite (depends on the environment);
  logic behind the protocol is covered by the fake.
- Round-trip `Config.settings.vmMemoryMonitoring` (Codable, default when absent).

## Out of This Increment (YAGNI)

- minikube/cgroup internal peak (Tier 2, `minikube ssh`/`kubectl top` probe).
- CPU signals (hypervisor load / inside VM) for `--cpus`.
- Exact numeric recommendation ("--memory = N") and a consolidated advisor across all parameters.
- Persistent "idle peak" outside of runs (the live row is sufficient for working mode).
