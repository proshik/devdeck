# DevDeck — native macOS menu bar control deck for dev commands

A native macOS application built with Swift/SwiftUI, living in the menu bar. It launches,
stops, and displays the status of local dev commands and background daemons (e.g.
`kubectl port-forward`). Created to eliminate the routine of manually running local
dev-cycle commands in a terminal (colima / minikube / just / port-forward). The app is
generic and not tied to any specific project.

## Purpose

- Menu bar icon, available on all monitors → click opens a **minimalist popover control deck**:
  a list of commands and chains with launch/stop buttons and status indicators.
- **A separate regular window** — command editing, chain builder, live log viewer.
- Shows which daemon commands are running in the background.

## Stack and build

- **Language:** Swift, UI with SwiftUI + AppKit (`NSStatusItem`, `NSPopover`).
- **Build:** Xcode project (`DevDeck.xcodeproj`). Produces an `.app` bundle, `Info.plist`, icon,
  and live preview out of the box; the only path to future distribution (Mac App Store / notarization
  via Archive → Distribute).
- **`Info.plist`:** `LSUIElement = true` (no Dock icon, menu bar only). Sandbox-free —
  required for launching external processes and accessing arbitrary working directories.
- **Minimum macOS:** set to the current version of the developer's machine.

## Architectural decisions (locked)

- **Launching commands:** via `/bin/zsh -lc "<cmd>"` with a specified `currentDirectoryURL`, so
  that PATH from `~/.zshrc` is picked up (otherwise the GUI app won't find `just`/`colima`/`minikube`/`kubectl`).
- **sudo commands:** via `osascript … with administrator privileges` (native macOS password dialog).
  Marked with the `needsSudo` flag. All others use plain `zsh -lc`.
- **Daemons:** commands flagged `isDaemon` — long-lived, shown with a persistent indicator.
- **App quit:** if live daemons exist → dialog "Kill / Leave in Background / Cancel".
- **Chains:** sequential; the next command starts after the previous one succeeds; stops on
  error (if `stopOnError`), the failed step is highlighted.
- **Config:** JSON file (`~/Library/Application Support/DevDeck/config.json`), editable
  both by hand and from the UI. External edits are picked up by the FileWatcher. Malformed JSON → error
  in the UI; the last valid version is kept in memory.
- **Popover in the menu bar — minimalist** (control deck only). All editing and logs live in the main window.

## Project structure (target)

```
devdeck/
├── DevDeck.xcodeproj
├── DevDeck/
│   ├── DevDeckApp.swift            # @main, NSApplicationDelegate, LSUIElement
│   ├── Models/                     # Command, Chain (Codable)
│   ├── Store/                      # CommandStore (JSON load/save + FileWatcher)
│   ├── Process/                    # CommandRunner (protocol), ZshCommandRunner, ProcessManager (@Observable)
│   ├── MenuBar/                    # MenuBarController (NSStatusItem+NSPopover), PopoverView
│   ├── MainWindow/                 # MainWindowView, CommandEditorView, ChainEditorView, LogView
│   └── Resources/                  # Assets.xcassets (template icon), default-config.json
└── DevDeckTests/                   # ProcessManagerTests, CommandStoreTests
```

## Data model

- `Command`: `id: UUID`, `name`, `command: String`, `workingDirectory: String?`,
  `isDaemon: Bool`, `needsSudo: Bool`, `env: [String:String]`.
- `Chain`: `id: UUID`, `name`, `commandIDs: [UUID]`, `stopOnError: Bool`.

## Process states

`idle / running / daemonRunning / succeeded / failed(code)`. Published via `@Observable`
so the popover and the main window update in sync. Output (stdout+stderr) is streamed line by line
into a ring buffer capped by line count (guarding against memory leaks).

## Testing

- `ProcessManager` works behind the `CommandRunner` protocol → unit tests for the state machine and
  chains with a fake runner, no real process launches.
- `CommandStore` → JSON serialization round-trip tests.
- Run: Cmd-U in Xcode or `xcodebuild test`.

## Out of MVP scope (deferred)

- Re-attaching daemons by PID after an app restart (`state.json`).
- Pre-built buttons for common `just` targets of the user's project (status / logs / forward).
- Hotkeys, launch-at-login (`SMAppService`), cluster health indicator in the menu bar icon.

## Conventions

- Code language — Swift. Comments and UI text — per project context.
- Do not commit without an explicit request from the user.
- Do not add `Co-Authored-By` to commit messages.

## Detailed plan

See `docs/PLAN.md`.
