# Design: Tier 2 — minikube Memory from Inside the VM + OOM Detection

> Date: 2026-06-11. Status: in implementation. Continuation of Tier 1
> (`2026-06-10-vm-memory-monitoring-design.md`).

## Goal

Answer "is `minikube --memory` optimal and why does the build fail":
internal minikube node memory peak per run vs its limit, the count of concurrent
`rustc` processes and their combined RSS, and OOM-kill detection (kubectl + dmesg).

## Facts (verified live on 2026-06-11, supersede PLAN.md)

- **The PLAN.md diagnosis "read the ssh-session cgroup root directly" was wrong.** Inside
  `minikube ssh` the cgroup namespace root `/sys/fs/cgroup/memory.{current,max}` is the
  **cgroup of the node container itself**: `memory.max = 4 194 304 000` = exactly the
  docker node limit (= `minikube --memory=4000`, not 6144 as the plan assumed).
  This is the real build ceiling.
- `kubepods/memory.max` = 9.69 GiB ≈ the entire colima VM — kubelet is unaware of
  the container's docker limit; this value is **misleading**, do not use it.
- `memory.current`/`memory.peak` at the root are saturated by page cache (peak = limit
  always) → useless as a build peak. The real OOM-risk signal is
  **`memory.stat → anon`** (non-reclaimable memory; this is what rustc consumes).
  We accumulate the anon peak ourselves via sampling (cgroup v2 provides no anon-peak).
- `ps -e -o rss=,comm=` inside the node works (procps) → rustc count and RSS sum.
- One combined probe `minikube ssh -- sh -c 'stat+max+ps'` ≈ 0.45 s —
  acceptable for a 1 Hz sampler off the main thread.
- `dmesg` inside the node is readable without sudo; kubectl scan
  `lastState.terminated.reason == "OOMKilled"` works (no events currently).
- Binary: `/opt/homebrew/bin/minikube`, fallback `/usr/bin/env minikube`
  (same pattern as colima in `LiveVMMemoryProbe`).

## Components

### 1. `Diagnostics/MinikubeMemory.swift`
- `struct MinikubeSample: Equatable { anonBytes, limitBytes: UInt64,
  rustcCount: Int, rustcRSSBytes: UInt64 }` + `fraction`, `headroomFraction`,
  `format()` (`"anon 2.0 / 3.9 GiB · 52%"`).
- Pure parser `parse(_ output: String) -> MinikubeSample?` of script output:
  `grep '^anon ' memory.stat; cat memory.max; ps -e -o rss=,comm=`.
  `memory.max == "max"` or garbage → nil (don't show without a limit, like colima).
- `protocol MinikubeProbing: Sendable { func sample() -> MinikubeSample? }`.
- `LiveMinikubeProbe`: one `minikube ssh` per sample via `ProcessTree.run`;
  minikube not running → empty output → nil.

### 2. `Diagnostics/OOMInspector.swift`
- `struct OOMEvent: Equatable { namespace, pod, container: String,
  restartCount: Int, finishedAt: String? }`.
- Pure parser `parseOOMKilled(_ json: String) -> [OOMEvent]`
  (`kubectl get pods -A -o json`).
- `protocol OOMInspecting: Sendable { func scan() -> OOMReport? }`,
  `OOMReport { events: [OOMEvent], dmesgLines: [String] }`.
- `LiveOOMInspector`: kubectl scan + `minikube ssh -- dmesg | grep -iE
  'killed process|oom'` (tail). dmesg catches OOMs outside pods (docker build
  inside the node) — kubectl doesn't see those.

### 3. `ProcessManager`
- Injects: `minikubeProbe`, `oomInspector`,
  `isMinikubeMonitoringEnabled: () -> Bool` (defaults — live + `{ true }`).
- The existing VM sampler on each tick additionally (if flag) probes
  minikube in the same `Task.detached` → `cachedMinikubeSample` (on main) +
  accumulates `MinikubeRunStats` per active run.
- `struct MinikubeRunStats`: `peak: MinikubeSample` (max by anon),
  `maxRustcCount`, `maxRustcRSSBytes` (independent maximums);
  `mutating absorb(_:)` — pure, tested.
- Flush on termination (same 4 call sites as `flushVMPeak`):
  `minikube peak for «X»: anon 2.8 / 3.9 GiB (headroom 28%) · rustc max 6 ·
  rustc RSS max 4.1 GiB` + threshold hints from Tier 1
  (>30% → can lower `--memory`, <10% → raise it).
- OOM scan: on `.terminated(code != 0)` not due to a user stop (and for
  a chain-in-terminal) when the flag is enabled — detached `oomInspector.scan()`,
  result to `DiagnosticLog` (events → warn; empty → quiet info "clean").
- `cachedMinikubeSample` is cleared when the sampler stops (no active run —
  no row, zero idle overhead; popover tick does NOT probe minikube).

### 4. Settings and UI
- `Settings.minikubeMemoryMonitoring: Bool = true` (decodeIfPresent → default),
  `CommandStore.setMinikubeMonitoring`, a second toggle in `SettingsView`,
  closure wiring in `AppDelegate`.
- `PopoverView`: row `VM minikube  anon X.X / 3.9 GiB · NN% · rustc N`
  below the colima row, colour by `pressureColor(fraction)`; visible only while
  a run is active (sampler cache is non-nil).

## Testing (TDD, following Tier 1 pattern)
- `MinikubeSample.parse` parser: valid output / `max` / garbage / no rustc.
- `format`/`fraction` on fixtures.
- `MinikubeRunStats.absorb`: independent maximums.
- `ProcessManager` + `FakeMinikubeProbe`: peak accumulates, flush on termination clears.
- `parseOOMKilled`: fixture with OOMKilled / without.
- `ProcessManager` + `FakeOOMInspector`: scan is called on failure, NOT called
  on success and user stop.
- Round-trip `Settings.minikubeMemoryMonitoring`.

## Out of Increment (YAGNI)
- cgroup of a specific build pod (the full node answers the limit question).
- metrics-server / `kubectl top` (dependency; ssh+cgroup has no dependencies).
- CPU signals, consolidated advisor, rustc crate name parsing from logs (Tier 1 [P5]).
