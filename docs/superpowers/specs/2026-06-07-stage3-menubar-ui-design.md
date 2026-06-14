# Stage 3 — Menu Bar UI (Popover Control Deck + Window Skeleton)

Date: 2026-06-07. Status: approved, ready for implementation planning.

## Context

Stages 0–2 are complete and committed: the accessory app skeleton (`NSStatusItem`, `LSUIElement`),
models + `CommandStore` (`@MainActor @Observable`, config + FileWatcher), `ProcessManager`
(`@MainActor @Observable`, command/chain state machine, logs in a ring buffer). 52 tests green.

Stage 3 delivers the first real UI: clicking the menu bar icon opens a **minimalist popover
control deck** (run/stop/status), plus a **main window skeleton** opens (content in Stage 4).

## Goals

- Replace the temporary Stage 0 menu with an `NSStatusItem` + `NSPopover` containing `PopoverView`.
- The control deck shows commands and chains from `CommandStore`, statuses from `ProcessManager`,
  and ▶/■ buttons that call `ProcessManager`.
- "Open DevDeck…" and the log button (☰) open the real main window (skeleton).
- Single observable state: popover and window read the same `store`/`manager`.

## Decisions (approved with the user)

- **Control deck layout — variant B**: "Commands" and "Chains" sections with headings; single-line footer.
- **Main window — skeleton now**: Stage 3 opens a real window (placeholder with a list/selected
  command); ☰ selects a command; Stage 4 adds the editor and `LogView`.
- "Quit" in Stage 3 — plain `terminate` (the "Kill/Leave/Cancel" dialog is Stage 5).

## Architecture

```
AppDelegate
 ├─ CommandStore        (@MainActor @Observable)  — config, FileWatcher; .start()
 ├─ ProcessManager      (@MainActor @Observable)  — state machine, logs
 ├─ AppModel            (@MainActor @Observable)  — UI state: selectedCommandID
 └─ MenuBarController   — NSStatusItem + NSPopover(NSHostingController(PopoverView))

DevDeckApp (SwiftUI)
 └─ Window("DevDeck", id:"main")  → MainWindowView (Stage 3 skeleton)
```

`AppDelegate` owns `store`, `manager`, `appModel`, `menuBarController`. In `applicationDidFinishLaunching`:
creates them, calls `store.start()`, registers the status item. Objects are passed to `PopoverView`
and `MainWindowView` (via environment/constructor).

## Components

### MenuBarController (`MenuBar/MenuBarController.swift`)
- `NSStatusItem` (variableLength), template icon (SF Symbol, same as Stage 0).
- `NSPopover` with `behavior = .transient`, `contentViewController = NSHostingController(rootView: PopoverView(...))`.
- Status item button click → toggle popover (show at button / close).

### PopoverView (`MenuBar/PopoverView.swift`) — SwiftUI, thin
- If `store.error != nil` → thin red banner at the top.
- "Commands" section: `ForEach(store.config.commands)` → `DeckRow`.
- "Chains" section: `ForEach(store.config.chains)` → `DeckRow`.
- Footer: "Open DevDeck…" (open window), "Quit" (`NSApp.terminate`).
- Row actions:
  - command: ▶ → `manager.run(cmd)`; ■ → `manager.stop(cmd.id)`; ☰ → select + open window.
  - chain: ▶ → `manager.run(chain, commands: store.commandsByID)`; ■ → `manager.stopChain(chain.id)`.
- Row status: `manager.states[cmd.id]` (for a chain — `manager.chainStates[chain.id]`, mapped to the same indicator).

### StatusIndicator (`MenuBar/StatusIndicator.swift`) — pure, testable
- `StatusIndicator.forCommand(_ state: ProcessManager.RunState?) -> Indicator`
- `StatusIndicator.forChain(_ state: ProcessManager.ChainState?) -> Indicator`
- `Indicator`: colour (grey/yellow/green/red), SF symbol, animation flag (spinner for running).
- Mapping: nil/idle → grey; running → yellow+spinner; daemonRunning → green; succeeded → grey
  (same as idle — no separate checkmark in MVP); failed → red. Button: running/daemonRunning → ■, otherwise ▶.

### AppModel (`AppModel.swift`) — `@MainActor @Observable`
- `var selectedCommandID: UUID?` — which command to show in the window (for ☰ and future LogView).
- Possibly an `openMainWindow()` helper (via `openWindow`/`NSApp.activate`).

### Main window (`MainWindow/MainWindowView.swift`) — Stage 3 skeleton
- `Window("DevDeck", id: "main")` in `DevDeckApp`.
- Stage 3: simple placeholder — command list + selected command indicator (`appModel.selectedCommandID`),
  label "Editor and logs — Stage 4". Opening: `openWindow(id:"main")` + `NSApp.activate(ignoringOtherApps:true)`
  (window comes to front, app stays accessory — no Dock icon).

### CommandStore — small addition
- `var commandsByID: [UUID: Command]` (computed) — for `manager.run(chain, commands:)`.

## Data Flow

1. `store.start()` loads config → `store.config` (Observable).
2. `PopoverView` renders sections from `store.config`; indicators from `manager.states`/`manager.chainStates`.
3. ▶/■ call `manager` → state changes → SwiftUI redraws indicators synchronously.
4. ☰ / "Open DevDeck…" → `appModel.selectedCommandID` + open window.
5. External edit of config.json → FileWatcher → `store.config` → control deck updates.

## Testing

- **TDD (unit):** `StatusIndicator.forCommand/forChain` — mapping all states to colour/symbol/button/animation.
- **TDD (unit):** `CommandStore.commandsByID` round-trip.
- **SwiftUI views** — thin, verified by launching the app (manual end-to-end):
  popover opens on any monitor; ▶ on a real command → yellow→green/red; daemon green;
  ■ stops; ☰/"Open DevDeck…" open the window; no Dock icon.

## Out of Stage 3

- Command/chain editor, drag-and-drop ordering, live `LogView` — Stage 4.
- "Kill/Leave in Background/Cancel" dialog on quit with live daemons — Stage 5.
- Cluster health indicator in the menu bar icon, hotkeys, login autostart — out of MVP.

## Risks / Notes

- Opening a window from an accessory app: use `openWindow` + `NSApp.activate`; the window appears,
  activation policy stays `.accessory` (no Dock icon). Verify the window comes to the foreground.
- `NSPopover.transient` closes on a click outside — fine for a control deck; actions are instant.
- A chain needs `[UUID: Command]` — take from `store.commandsByID` at the time of launch.
