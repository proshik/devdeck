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
- **File-system-synchronized groups:** a new `.swift` under `DevDeck/` or `DevDeckTests/` is picked
  up automatically — never edit `project.pbxproj` by hand.
- **Releases** are produced only by the `release.yml` GitHub workflow
  (`gh workflow run release.yml -f bump=patch|minor|major`) — it signs, builds the DMG, updates the
  Sparkle appcast and the Homebrew cask. The suite runs as the FIRST step, before the version bump
  and every other side effect, so a red test aborts the release without publishing anything.
  `tests.yml` runs the same suite on every push to `main` and on pull requests.

## Architectural decisions (locked)

- **Launching commands:** via `/bin/zsh -lc "<cmd>"` with a specified `currentDirectoryURL`, so
  that PATH from `~/.zshrc` is picked up (otherwise the GUI app won't find `just`/`colima`/`minikube`/`kubectl`).
- **sudo commands:** via `osascript … with administrator privileges` (native macOS password dialog).
  Marked with the `needsSudo` flag. All others use plain `zsh -lc`.
- **Daemons:** commands flagged `isDaemon` — long-lived, shown with a persistent indicator.
- **Supervision** (all keyed off `Command.port` / `watchdogEnabled`): watchdog auto-restart, orphan
  adoption by PID after an app restart, and an occupied-port pre-check with a "kill the occupant"
  panel. Any feature that needs a supervised background process is expressed as a **synthetic
  daemon `Command`** and handed to this engine rather than growing its own lifecycle code.
- **App quit:** if live daemons exist → dialog "Kill / Leave in Background / Cancel". In-process
  listeners (built-in proxy engine, proxy bridge) are excluded — they cannot outlive the app and
  restore themselves on the next launch. Note: a daemon "kept in background" dies of SIGPIPE at its
  first log write, so the option is only real for quiet processes.
- **Proxy Manager.** Host side: share this Mac's egress as an HTTP proxy announced over Bonjour;
  the engine is `builtIn` (in-process `NWListener`, the default) or `gost` (external binary, adds
  SOCKS). Client side: pick a LAN proxy, or a **remote proxy** — `ssh -N -D` to a VDS plus a local
  bridge (the built-in engine with a SOCKS upstream) presented as `http://127.0.0.1:<port>`;
  nothing is installed on the VDS. Commands flagged `routeThroughProxy` get proxy env injected;
  with no usable proxy the run **fails loudly** instead of silently going direct. Credentials live
  in the Keychain, never in `config.json` or on a command line.
- **Chains:** sequential; the next command starts after the previous one succeeds; stops on
  error (if `stopOnError`), the failed step is highlighted.
- **Config:** JSON file (`~/Library/Application Support/DevDeck/config.json`), editable
  both by hand and from the UI. External edits are picked up by the FileWatcher. Malformed JSON → error
  in the UI; the last valid version is kept in memory.
- **Popover in the menu bar — minimalist** (control deck only). All editing and logs live in the main window.
- **Coding-agent tab restore.** Ghostty tabs running a coding agent — Claude Code or opencode, each
  behind its own `AgentSessionProvider` — are snapshotted and reopened after a reboot. The snapshot
  on disk is the user's only copy of their open tabs, so a snapshot from an earlier boot is never
  overwritten until that boot's restore is resolved, and a snapshot is written only when at least
  one tab resolved to a session. `kern.boottime` (compared to the second) tells a reboot from an app
  restart. Reading tabs and resolving titles happens off the main actor. See
  `docs/claude-tabs-restore-plan.md` (the base feature) and `docs/opencode-sessions-plan.md` (adding
  opencode behind the provider abstraction).

## Project structure

```
devdeck/
├── DevDeck.xcodeproj
├── DevDeck/
│   ├── DevDeckApp.swift / AppDelegate.swift  # @main, LSUIElement, quit dialog, wiring
│   ├── Models/          # Command, Chain, Config, AppRef, ProxyShare, RemoteProxy (Codable)
│   ├── Store/           # CommandStore (JSON load/save), ConfigCodec, FileWatcher
│   ├── Process/         # CommandRunner (protocol) + zsh/sudo/terminal runners, ProcessManager
│   │                    # (@Observable), StreamingProcess, RingBuffer, DaemonReaper, PortInspector
│   ├── Proxy/           # ProxyManager, built-in engine (listener/runner/config, HTTP parser),
│   │                    # Bonjour discovery + advertiser, client monitor, routing, browser, dp helper
│   ├── MenuBar/         # MenuBarController (NSStatusItem+NSPopover), PopoverView, ProxySectionView
│   ├── MainWindow/      # MainWindowView, editors, LogView, SettingsView, WindowAccessor
│   ├── Localization/    # LocalizationManager (live EN/RU switch) + L10n catalog
│   ├── Diagnostics/     # DiagnosticLog, memory/disk/cluster metrics, notifications
│   ├── Cleanup/         # DockerUsage (docker system df + volume listing probe), CleanupCommands (synthetic prune
│   │                    # commands per daemon), CleanupModel — behind the main window's Cleanup page
│   ├── ClaudeTabs/      # Snapshots the coding-agent tabs open in Ghostty (Claude Code, opencode)
│   │                    # and reopens them after a reboot: AgentSessionProvider (the per-agent
│   │                    # protocol) with ClaudeSessionProvider and OpencodeSessionProvider behind
│   │                    # it, GhosttyTabReader (AppleScript), TranscriptIndex (~/.claude session
│   │                    # titles), SessionResolver, RestorePlanner, BootTime, TabRestorer,
│   │                    # BackgroundSessions, ClaudeTabsStore, ClaudeTabsModel
│   ├── Update/          # UpdateController (Sparkle)
│   ├── Support/         # PrivateFile (0600 files), ShellQuoting
│   └── Resources/       # Assets.xcassets, default-config.json
└── DevDeckTests/        # state machine, chains, store, proxy (unit + loopback socket tests)
```

## Data model

- `Command`: `id: UUID`, `name`, `command: String`, `workingDirectory: String?`,
  `isDaemon`, `needsSudo`, `env: [String:String]`, plus `watchdogEnabled`, `port: Int?`,
  `routeThroughProxy`, `openInTerminal`, `keepTerminalOpen`, `promptForDirectory`,
  `appsToQuit: [AppRef]`.
- `Chain`: `id: UUID`, `name`, `commandIDs: [UUID]`, `stopOnError: Bool`.
- `ProxyShare` (host side): `port`, `authEnabled`, `username`, `serviceName`, `engine`
  (`builtIn` / `gost`). Password → Keychain.
- `RemoteProxy` (client side): `id`, `name`, `localPort`, `socksPort`, `tunnelCommandID` — the ssh
  tunnel is a normal, user-editable deck command; only its id is stored here.
- Every field decodes with a default (`config.json` is hand-editable), so adding one needs no
  `schemaVersion` bump.

## Process states

`idle / running / daemonRunning / succeeded / failed(code)`. Published via `@Observable`
so the popover and the main window update in sync. Output (stdout+stderr) is streamed line by line
into a ring buffer capped by line count (guarding against memory leaks).

## Testing

- Run: Cmd-U in Xcode, or from the terminal —
  `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck
  -destination 'platform=macOS'`. **The prefix is required** (`xcode-select` points at
  CommandLineTools); add `-only-testing:DevDeckTests/<Class>` to run one class.
- **Probe pattern:** every external dependency is injected behind a protocol — fake runner, fake
  Bonjour, fake Keychain, fake 0600 files, fake SOCKS server — so unit tests launch no processes and
  touch no network, Keychain or real paths. Follow it for anything new.
- `ProcessManager` state machine and chains → fake runner; `CommandStore` → round-trip tests.
- The proxy engine additionally has **loopback socket tests** (a real `NWListener`, a real echo
  server, a fake SOCKS5 server): protocol details belong in the pure-function tests, and these
  cover the plumbing.

## Deferred

- SOCKS in the built-in proxy engine (the `gost` engine covers it) and an internal WKWebView
  browser (the proxied Chrome instance covers logins).
- Pre-built buttons for common `just` targets of the user's project (status / logs / forward).

## Conventions

- Code language — Swift. Comments and UI text — per project context.
- Do not commit without an explicit request from the user.
- Do not add `Co-Authored-By` to commit messages.

## Detailed plan

See `docs/PLAN.md`.
