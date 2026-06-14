# DevDeck — Implementation Plan

## Context

The user frequently runs a set of commands manually in the terminal as part of the local dev cycle for myproject:
`colima stop/start`, `minikube stop/start`, `just dev-start/dev-build` (in a specific directory),
`sudo purge`, and keeps background `kubectl port-forward` processes running as daemons. Commands are run
individually or together (full restart). A native, stable macOS application with a menu bar icon
(accessible on all monitors) is needed: click → minimalist popover control deck for launching/stopping and
viewing status, plus a separate window for editing commands and viewing logs. The goal is to eliminate
terminal busywork and see which daemons are running in the background.

The project lives in a separate directory alongside myproject: `/Users/proshik/dev/devdeck`.

## Decisions (agreed with user)

- **Stack:** Swift + SwiftUI/AppKit, native.
- **Build:** Xcode project (`.xcodeproj`).
- **Command execution:** `/bin/zsh -lc "<cmd>"` with `currentDirectoryURL` (PATH from `~/.zshrc`).
  `sudo` → `osascript … with administrator privileges`.
- **Daemons on quit:** dialog "Kill / Leave in Background / Cancel".
- **Chains:** sequential, stop on error.
- **Config:** JSON, editable both manually and from the UI.
- **popover** — minimalist; editing/logs — in a separate window.

## Status

MVP (Stage 0–5) and post-MVP improvements — **closed and committed**, tests green.
Memory monitoring: Tier 1 (colima, `772c45c`) and **Tier 2 (minikube from inside the VM + OOM detection,
2026-06-11)** — done. Remaining Tier 1 tail items (pressure/swap-rate/compressor/`-j`) and
"cheapest first step" — on hold.

---

## Implementation Stages (MVP)

### Stage 0 — Project Scaffold ✅
- [x] Create `DevDeck.xcodeproj` (macOS App, SwiftUI).
- [x] `Info.plist`: `LSUIElement = true`, sandbox-free.
- [x] `DevDeckApp.swift`: `@main`, `NSApplicationDelegate`, register `NSStatusItem`.
- [x] Verification: launches, icon in menu bar, not in Dock.

### Stage 1 — Models and Store ✅
- [x] `Models/Command.swift`, `Models/Chain.swift` (+ `Config.swift`, `AppRef.swift`), `Codable`.
- [x] `Store/CommandStore.swift`: load/save `~/Library/Application Support/DevDeck/config.json`.
- [x] Copy `default-config.json` on first launch.
- [x] FileWatcher (`DispatchSource`) — picks up external edits.
- [x] Safe handling of malformed JSON (retain last valid version, show error in UI).
- [x] Tests: round-trip JSON, lookup, mutations, codec.

### Stage 2 — Process Execution ✅
- [x] `Process/CommandRunner.swift`: protocol `run(...) -> AsyncStream<Output>` + stop.
- [x] `Process/ZshCommandRunner.swift`: `Process` with `/bin/zsh -lc`, `currentDirectoryURL`, env.
- [x] `Process/SudoCommandRunner.swift`: `needsSudo` → AppleScript `with administrator privileges`.
- [x] `Process/ProcessManager.swift` (`@Observable`): state machine
  `idle/running/daemonRunning/succeeded/failed`.
- [x] Line-by-line streaming of stdout+stderr into a ring buffer (`RingBuffer`) with a line limit.
- [x] Methods `run(command)`, `run(chain)`, `stop(id)`; sequential chains with stop on error.
- [x] Grandchild pipe drain: force-finish via grace timer (bug "lost terminal").
- [x] Tests: state machine, chains, real runner, routing — with fake runner.

### Stage 3 — Menu Bar UI ✅
- [x] `MenuBar/MenuBarController.swift`: `NSStatusItem` + `NSPopover`.
- [x] `MenuBar/PopoverView.swift`: minimalist list of commands/chains.
- [x] Status dot: gray / yellow-spinner / green-daemon / red (pure-SwiftUI spinner).
- [x] ▶/■ button, small "logs" button, footer "Open DevDeck" / "Quit".

### Stage 4 — Main Window ✅
- [x] `MainWindow/MainWindowView.swift`: list + navigation.
- [x] `CommandEditorView.swift`: name, command, directory (`NSOpenPanel`), daemon/sudo toggles, env.
- [x] `ChainEditorView.swift`: chain assembly, drag-and-drop ordering.
- [x] `LogView.swift`: live output of the selected process, auto-scroll, clear, stop.
- [x] "Memory freeing before command" feature: list of GUI apps (ranked by RAM) → graceful
  quit before launch, relaunch after; a chain quits the merged set of apps once
  (`AppController`/`LiveAppController`, `unionAppsToQuit`).

### Stage 5 — Quit and Default Config ✅
- [x] `applicationShouldTerminate`: when live daemons exist — `NSAlert` "Kill / Leave in Background / Cancel".
- [x] `Resources/default-config.json`: myproject commands (colima/minikube start-stop, `just dev-start`,
  `just dev-build`, `sudo purge`, two `kubectl port-forward` [isDaemon]) + "Full Restart" chain.
- [x] `DefaultConfigTests`: default config is valid.

---

## Post-MVP Improvements

### Diagnostic Logging ✅
- [x] `Diagnostics/DiagnosticLog.swift`: file log with per-session rotation, thread-safe.
- [x] Crash handlers: `NSSetUncaughtExceptionHandler` + signal handlers with `backtrace_symbols_fd`.
- [x] Logging for operations (launch/stop/chains/memory/quit).
- [x] "Log" button in the popover → open `devdeck.log` in Finder.

### Memory in Popover Header + Custom Icon ✅
- [x] Popover header: "Used / total GB · %", auto-refreshed once per second (`TimelineView`).
- [x] Memory pressure bar with color coding (green <70% / yellow <85% / red).
- [x] Binary GiB (as Apple/htop), not decimal GB — eliminates the 17 vs 16 discrepancy.
- [x] Swap as a separate line "Swap X.X GB", shown in orange when non-zero (`vm.swapusage`).
- [x] Custom menu bar glyph (mixer/faders, template-image) + `.app` icon (AppIcon.appiconset).

### UX Fixes ✅
- [x] Red window close button does not quit the app (`applicationShouldTerminateAfterLastWindowClosed=false`).
- [x] Quit confirmation (when no daemons running); eliminated dialog loop on "Cancel" with live daemons.
- [x] Popover footer padding (buttons no longer hug the border).
- [x] Removed square focus ring behind the first button (`.focusEffectDisabled()`).
- [x] Delete individual chain step (⊖ button in `ChainEditorView`).

### Popover: Sections and Collapsing ✅
- [x] "Commands" section split into "Commands" (`isDaemon=false`) and "Daemons" (`isDaemon=true`).
- [x] Collapsible sections: clickable header with counter (green — active / gray — total) and chevron.
- [x] Section collapsed state persisted across opens and restarts (`@AppStorage`).
- [x] Popover size 300×440 → 360×560.

### Native Notifications ✅ (`7203d12`)
- [x] `UserNotifications`: daemon came up / died on its own / failed to start (with sound), command/chain failure.
- [x] Manual stop and success — silent; adopted daemon — silent "Adopted".

### Adopting Orphaned Daemons After Restart ✅ (`d001810`)
- [x] On startup, search for an orphaned process (`ppid==1`) with a matching command → display "adopted".
- [x] Stop — kill the process tree (`ProcessTree.terminate`); re-running over an adopted daemon kills the old one.
- [x] Implemented via command-string matching (more reliable than a saved PID / `state.json`).

### Launching Commands/Chains in Ghostty Terminal ✅ (`0bb968b` + chains)
- [x] `openInTerminal` flag on command and chain; Window/Tab mode (shared `@AppStorage`).
- [x] Window — `NSWorkspace.openApplication`; Tab — native Ghostty AppleScript (`new tab` + surface `command`), no Accessibility (requires "Automation").
- [x] Tracking via pid/exit sentinels (same `.started/.terminated`), stop — `killTree`, protective start timeout.
- [x] Full chain as a single script in one tab (`ChainScript`): steps with markers, `stopOnError` via `&&`, sudo in tab, daemons in background.

### Production-Ready ✅ (`3eb3549`)
- [x] README, LICENSE (MIT), CHANGELOG; packaging into `.dmg` (`scripts/build-dmg.sh`, `justfile`); min. macOS 15.

---

## Verification (end-to-end)

- [x] Run in Xcode → icon in menu bar, not in Dock.
- [x] Popover opens on any monitor, shows pre-populated commands.
- [x] Regular command (echo / "List Files") → status yellow → green; live output in `LogView`; PATH found.
- [x] Daemon → persistent green; ■ stops it.
- [x] Chain → steps execute in sequence; error → stop, step turns red.
- [x] `xcodebuild test` → tests green.
- [ ] `sudo purge` → native password dialog → executes (not yet confirmed live).
- [ ] `kubectl port-forward` → `lsof -i :PORT` confirms port (not yet confirmed live).
- [ ] Full quit scenario with a live daemon: "Leave in Background" → port alive, "Kill" → port free (not yet confirmed live).

---

## Next Block: Memory Monitoring for Heavy Rust Builds in minikube (deferred)

> Captured from a background multi-agent analysis (3 lenses: macOS internals,
> minikube/VM, what's already in the code). The popover currently shows only **host** RAM + swap,
> while the `just dev-build` build runs behind three layers of nesting — not enough for OOM diagnosis.

**The core problem is nested memory ceilings.** The real chain (numbers from `default-config.json`):

```
Host Mac 16 GiB  →  colima VM 10 GiB / 6 CPU (vz, docker)  →  minikube node (--memory=6144)  →  build pod cgroup
```

From outside the VM the host sees the hypervisor (`com.apple.Virtualization`) as a single opaque RSS blob —
it **cannot see** individual `rustc` processes, their count, or the current crate. `rustc` can be killed by the OOM killer
*inside* the VM while the Mac still has free memory. The math: cargo defaults to `-j` = number of VM cores →
~6 × 1.5 GB ≈ 9 GB against the limit → headroom is razor-thin. Memory peaks **late**
(final codegen + fat-LTO + linking at the end of the DAG).

### Tier 1 — From the Host, Cheap, No VM Entry (do first)
- [ ] **[P5] Memory pressure level** (normal/warn/critical) — kernel verdict, predicts thrashing
  before stalls. `kern.memorystatus_vm_pressure_level` + push `DispatchSource.makeMemoryPressureSource`. → menu bar icon.
- [ ] **[P5] Swap-out/in rate** (pages/sec) — distinguishes "full but stable" from "actively
  thrashing"; static "Swap N GB" lags. `host_statistics64(HOST_VM_INFO64)` `swapins/swapouts`, delta/dt. → main window.
- [x] **[P5] Hypervisor RSS vs VM limit + peak per run** — ✅ DONE (`772c45c`). Process
  `com.apple.Virtualization.VirtualMachine` (footprint) vs limit from `colima list --json`; live
  line in popover + peak per run in log with a `colima --memory` hint; flag
  `Config.settings.vmMemoryMonitoring` + "Settings"; probe off the main thread.
  Real dev-build peak: **6.2/10 GiB (headroom 38%)** → colima --memory can be lowered to ~8.
  Spec: `docs/superpowers/specs/2026-06-10-vm-memory-monitoring-design.md`.
- [ ] **[P5] OOM/non-zero exit detection + crate name** — cheap and unambiguous: `signal: 9` /
  `could not compile X` → X = the monster crate. `terminationStatus==9` + regex over the log tail (exit code already available). → log.
- [ ] **[P4] Peak memory per build → to log** — teaches "build peaks at X GB". `DiagnosticLog` already records
  start/finish — add a summary. → log per run.
- [ ] **[P4] Compressor saturation** — early warning between "RAM full" and "swap started".
  `host_statistics64` `compressor_page_count` + `vm.compressor.pages_compressed`. → main window.
- [ ] **[P3] Effective `-j` vs RAM limit** — justification for `CARGO_BUILD_JOBS=3` (rule: "limit_GB / 2
  per rustc"). Parse `-j`/env of the command, default = VM cores. → main window.

### Tier 2 — Probe Inside the VM (`minikube ssh`) ✅ DONE 2026-06-11
- [x] Number of concurrent `rustc` processes + their total RSS — `ps -e -o rss=,comm=` in the node, maximums per run.
- [x] Node memory peak per run vs its limit — **anon** from `memory.stat` (see clarifications below),
  limit = `memory.max` of the node's cgroup namespace root (= `minikube --memory`).
- [x] OOM detection after a failed run: kubectl scan `lastState.terminated.reason=="OOMKilled"`
  + `dmesg | grep -iE 'killed process|oom-kill'` (catches victims outside pods, e.g. docker build in the node).
- Implementation: `Diagnostics/MinikubeMemory.swift` (`MinikubeProbing`/`LiveMinikubeProbe`,
  one ssh round-trip ≈0.45 s per sample, strictly off main), `Diagnostics/OOMInspector.swift`;
  `ProcessManager` sampler probes minikube only while there is an actively RUNNING run
  (idle daemons don't count — ssh doesn't hammer for hours); flag
  `Config.settings.minikubeMemoryMonitoring` + toggle in "Settings"; line
  "VM minikube anon X/3.9 GiB · % · rustc N" in popover during a run; peak + hint
  for `minikube --memory` in the terminal log. Spec:
  `docs/superpowers/specs/2026-06-11-minikube-memory-tier2-design.md`.

#### Clarifications Based on Findings (correct the diagnosis from 2026-06-10)
- **"Direct path = ssh session cgroup" was WRONG:** root `/sys/fs/cgroup/memory.{current,max}`
  inside `minikube ssh` is the cgroup of **the node container itself** (cgroup namespace):
  `memory.max = 4 194 304 000` = docker limit of the node. This is the real build ceiling.
- **The live cluster was created with `--memory=4000`, not 6144** from default-config: `--memory` applies
  only when creating the profile; to actually give 6 GiB — `minikube delete && minikube start --memory=6144`.
- `kubepods/memory.max` = 9.69 GiB ≈ entire colima VM — kubelet is unaware of the node's docker limit,
  the value is misleading → do not use.
- `memory.current`/`memory.peak` are saturated by page cache (peak ≡ limit) → peak is useless;
  the real OOM-risk signal is `memory.stat → anon` (currently ~2.2 of 3.9 GiB);
  we track the anon peak ourselves via 1 Hz sampling.
- kubelet — cgroupfs driver: path `kubepods` (NOT `kubepods.slice`).

### Do Not Implement (confirmed as noise)
- [ ] ~~`purgeable`~~ (≈0 under load), ~~legacy `vm.memory_pressure`~~ (jumps 0↔13),
  ~~rate page-faults~~ (high even under normal conditions).

### Cheapest First Step (building on current code)
- [ ] On each run tick, sample the build process footprint + host pressure level + swap rate.
- [ ] Accumulate peak between `.started` and `.terminated` (PID already flows through `RunnerOutput.started`,
  currently ignored in `apply`; `ProcessManager.apply` hooks exist).
- [ ] Write a summary to log: "peak RSS X GB, swap Y, pressure Z" (`DiagnosticLog`, `TimelineView` 1-sec tick).
- [ ] On exit, detect OOM-kill and highlight the crate.
- [ ] Explicitly pin `minikube --memory` so the ceiling is known.
  (Tier 2 — probe into the VM — as a separate pass.)

---

## Possible Extensions (NOT in MVP)

- [x] ~~Adopting daemons by PID after restart~~ — done (command-string matching, not `state.json`). `d001810`
- [ ] Buttons for myproject-loop: `just dev-status`, `just dev-logs <svc>`, `just dev-forward`.
- [ ] Hotkeys, launch at login (`SMAppService`), cluster health indicator in the menu bar icon.
