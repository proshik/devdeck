# Stage 4 — Main Window + "Free Memory" Feature

Date: 2026-06-07. Status: approved, ready for implementation planning.

## Context

Stages 0–3 are complete (63 tests): the tray control deck runs/stops/monitors commands and
chains via `ProcessManager`, config in `CommandStore`. The main window is still a placeholder.

This stage: (1) **main window** — command/chain editor + live LogView (output already accumulates
in `ProcessManager.logs`); (2) **new feature**: before running a command/chain, quit selected
memory-hungry GUI apps, and after the run restore them (so heavy `just dev-start/dev-build`
runs don't hit the RAM ceiling).

## Decisions (approved with the user)

- **Per-command binding**: each command has its own list of apps to quit.
- **Graceful `quit` only** (no force). If an app doesn't close (unsaved data) — don't force it,
  continue; don't relaunch it (since we didn't close it).
- **Always relaunch** after the command (success/error/stop) — only the ones we actually closed.
- **Source of the list** — GUI apps (`NSWorkspace`), sorted by RAM (numbers from `top`).
- **Chain**: quits the **union** of `appsToQuit` across all steps once before the chain,
  relaunches once after (no toggling between steps).
- **Daemons** — secondary case (relaunch on daemon stop); primary use case is chains.

## Architecture

App management is behind the `AppController` protocol (like `CommandRunner`): orchestration in
`ProcessManager` is tested with a fake, without actually quitting Chrome.

```
Models/AppRef.swift        struct AppRef { bundleID, name } (Codable); Command.appsToQuit: [AppRef]
Process/AppController.swift protocol AppController + RunningApp
Process/LiveAppController.swift  NSWorkspace + top (memory), quit/relaunch
ProcessManager              orchestrates quit→run→relaunch (injects AppController)
MainWindow/*                editor, chain builder, LogView (Stage 4 UI)
```

## Components

### Model (`Models/AppRef.swift`, modify `Command`)
```swift
struct AppRef: Codable, Hashable {
    var bundleID: String
    var name: String
}
// Command += var appsToQuit: [AppRef] = []   (robust decode: decodeIfPresent ?? [])
```

### AppController (`Process/AppController.swift` + live + fake)
```swift
struct RunningApp: Sendable, Equatable, Identifiable {
    var bundleID: String; var name: String; var memoryBytes: UInt64
    var id: String { bundleID }
}
protocol AppController: Sendable {
    func runningApps() -> [RunningApp]                               // GUI apps, sorted by RAM desc.
    func quit(_ bundleIDs: [String], timeout: TimeInterval) async -> [String]  // returns ACTUALLY closed ones
    func relaunch(_ bundleIDs: [String])
}
```
- **LiveAppController:** `NSWorkspace.shared.runningApplications`, filtered to
  `activationPolicy == .regular` (regular GUI apps with bundleIdentifier). Memory: `top -l 1
  -stats pid,mem` (or `proc_pid_rusage` phys_footprint), aggregated per app (pid→bundleID).
  `quit`: `NSRunningApplication.terminate()` (gracefully) for running apps with that bundleID;
  wait ≤ timeout until they disappear from `runningApplications`; return the closed ones. `relaunch`:
  `NSWorkspace.urlForApplication(withBundleIdentifier:)` → `openApplication`.
- **FakeAppController:** scriptable — sets runningApps, which bundleIDs will "close" on quit,
  records quit/relaunch history for assertions.

### Orchestration in ProcessManager
- Injects `appController: AppController` (default live; tests — fake). Quit timeout — parameter (default 10 s).
- **Command** with non-empty `appsToQuit`: before running `await appController.quit(ids, timeout)` (log
  "Quitting …"); run; **on termination (always)** `appController.relaunch(closed)` (log "Relaunching …").
- **Chain**: union of all step `appsToQuit` → quit once before the driver loop → relaunch once
  after completion (any chain terminal state). Steps inside a chain do NOT apply their individual
  `appsToQuit` (only the union at the chain level).
- Quit/relaunch progress is written as lines to the log buffer of the respective command/chain.

### Main window UI (Stage 4)
- `MainWindowView`: `NavigationSplitView` — command+chain list on the left (selection), editor/logs on the right.
- `CommandEditorView`: name, command (multiline), working directory (`NSOpenPanel`), toggles
  `isDaemon`/`needsSudo`, `env` editor (key-value pairs), **"Free Memory"** section — a live
  list of GUI apps by RAM with checkboxes (+ already selected ones even if not currently running),
  a "Refresh" button. Save → `CommandStore` (mutations).
- `ChainEditorView`: name, ordered command list (drag-and-drop), `stopOnError` toggle.
- `LogView`: live output of the selected command from `ProcessManager.logs`, auto-scroll, clear, stop.
- `CommandStore` += mutations: `upsert(command)`, `delete(commandID:)`, `upsert(chain)`,
  `delete(chainID:)` — modify a copy of `config` and save atomically. Reordering chain steps
  (drag-and-drop) = `upsert(chain)` with the new `commandIDs` order.

## Data Flow

1. Editor reads `store.config` and `appController.runningApps()`; edits → `store.upsert/delete` → atomic write → FileWatcher (no self-reload, Equatable guard).
2. ▶ command/chain with `appsToQuit` → `ProcessManager`: quit (log) → run → relaunch (log); status indicators and LogView update on main.

## Testing (TDD on the testable layer)

- `AppRef` round-trip; `Command.appsToQuit` round-trip + robust decode (missing key → []).
- `FakeAppController` → `ProcessManager` orchestration: quit-before/relaunch-after; **union in chain —
  one quit/relaunch**; "didn't close → don't relaunch"; empty `appsToQuit` → runner doesn't touch AppController.
- `CommandStore` mutations (`upsert`/`delete`) round-trip; step reordering via `upsert(chain)`.
- UI views are thin → verified by launching the app (editor saves; picker shows apps by RAM;
  checkbox writes to `appsToQuit`; LogView shows live output; real quit/relaunch of Chrome).

## Out of Stage 4

- "Kill/Leave/Cancel" dialog on quit with live daemons + initial `default-config.json` — Stage 5.
- Cluster health indicator, hotkeys, login autostart — out of MVP.

## Risks / Notes

- **TCC/Automation**: cross-app `quit`/`relaunch` without sandbox usually doesn't require
  Apple Events permission (`terminate()` — not AppleScript), but a system prompt may appear on
  the first quit — test in production, document if needed.
- **Memory per app**: an app may have multiple processes (helpers) — aggregate best-effort;
  `top` output parsing is fragile (format), wrap it and don't crash on surprises.
- Graceful `quit` may not free RAM if the app showed a save dialog — this is an intentional
  trade-off (data safety over RAM reclaim); log "… did not close".
- Daemon relaunch happens only when the daemon is stopped — acceptable (daemons are a secondary use case).
