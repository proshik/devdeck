<div align="center">

# DevDeck

**A native macOS menu bar control deck for your local dev commands and background daemons.**

Launch, stop, and monitor local dev commands and long-running daemons
(`colima`, `minikube`, `just`, `kubectl port-forward`, …) — without the chore of juggling terminals.

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-1575F9?logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](https://swift.org)
[![UI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-1575F9)](#stack)
[![Languages](https://img.shields.io/badge/i18n-EN%20%2F%20RU-2EA043)](#language)
[![Dependencies](https://img.shields.io/badge/dependencies-none-2EA043)](#packaging-a-dmg)
[![License](https://img.shields.io/badge/license-MIT-2EA043)](LICENSE)

</div>

> Swift + SwiftUI/AppKit · `NSStatusItem` + `NSPopover` · sandbox-free · `LSUIElement` (menu bar only, no Dock icon).

---

## Features

- **Menu bar deck** on every display: click the icon → a minimalist popover with your
  **commands**, **daemons**, and **chains**; run/stop buttons and status indicators
  (grey / yellow spinner / green daemon / red).
- **Collapsible sections** with an active counter; the collapse state is remembered across launches.
- **Main window**: command editor, chain builder (drag-and-drop ordering), live logs.
- **Chains** — sequential execution, stop on error, the failed step highlighted.
- **sudo commands** — via the native macOS password dialog (`osascript … with administrator privileges`).
- **Memory freeing** — gracefully quit memory-hungry GUI apps before a heavy build and
  relaunch them afterwards (for a memory-hungry `just dev-build`).
- **Memory header** — RAM (used/total/%), swap, color by pressure; auto-refreshes once a second.
- **Diagnostics** — a file log + crash reports; the "Log" button reveals `devdeck.log` in Finder.
- **JSON config**, editable both by hand and from the UI; external edits are picked up by a FileWatcher,
  broken JSON → an error in the UI while the last valid version is kept in memory.
- **Bilingual UI (EN / RU)** — switch the interface language live in Settings, no restart required.
- **In-app auto-update (Sparkle)** — get new versions automatically, or see when one is available.

## Install

```sh
brew install --cask proshik/tap/devdeck
```

DevDeck is **not notarized** (free distribution), so Homebrew quarantines the download and Gatekeeper
blocks the first launch. Clear it once:

```sh
xattr -dr com.apple.quarantine "$(brew --prefix)/Caskroom/devdeck"/*/DevDeck.app 2>/dev/null \
  || xattr -dr com.apple.quarantine /Applications/DevDeck.app
```

(or right-click `DevDeck.app` → **Open**). After that, **updates are delivered in-app via Sparkle** and
are not quarantined — no need to repeat this. Toggle automatic updates in **Settings → Updates**; when
off, the popover shows a small indicator when a newer version is available.

No Homebrew? Grab the `.dmg` from [Releases](https://github.com/proshik/devdeck/releases) — see
[Installing on another machine](#installing-on-another-machine-unsigned) below.

## Requirements

- **macOS 15.0 (Sequoia)+** — the target minimum (deployment target); also runs on macOS 26 (Tahoe).
  It can't go below 14.0 — the code uses macOS 14+ API (`@Observable`, `.focusEffectDisabled()`).
- **Xcode 16+** to build.
- Optional: [`just`](https://github.com/casey/just) — for the short commands in the `justfile`.

## Stack

- **Language:** Swift, UI in SwiftUI + AppKit (`NSStatusItem`, `NSPopover`).
- **Build:** an Xcode project (`DevDeck.xcodeproj`) — produces the `.app` bundle, `Info.plist`, icon,
  and live previews out of the box; the path to eventual distribution (Mac App Store / notarization).
- **`Info.plist`:** `LSUIElement = true` (no Dock icon, menu bar only). No sandbox — it needs to launch
  external processes and reach arbitrary working directories.
- **Zero third-party dependencies.**

## Build & run

**With Xcode:** open `DevDeck.xcodeproj`, pick the `DevDeck` scheme, ⌘R.

**From the terminal:**

```sh
xcodebuild build -project DevDeck.xcodeproj -scheme DevDeck \
  -configuration Debug -derivedDataPath build/dd
open build/dd/Build/Products/Debug/DevDeck.app
```

**With `just`:** `just run`

## Tests

⌘U in Xcode, or:

```sh
xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'
```

`just test`. The unit tests exercise the `ProcessManager` state machine and chains on a fake
runner (no real processes are launched) + config round-trip, the ring buffer, memory formatting, and more.

## Configuration

File: `~/Library/Application Support/DevDeck/config.json` (copied from the bundled
`default-config.json` on first launch). You can edit it by hand — changes are picked up automatically.

```jsonc
{
  "commands": [
    {
      "id": "UUID",
      "name": "just dev-build",
      "command": "just dev-build",
      "workingDirectory": "/path/to/project",  // optional
      "isDaemon": false,                         // a long-running daemon?
      "needsSudo": false,                        // run with admin rights?
      "env": { "CARGO_BUILD_JOBS": "3" }         // optional extra env
    }
  ],
  "chains": [
    { "id": "UUID", "name": "Full restart", "commandIDs": ["UUID", "..."], "stopOnError": true }
  ]
}
```

## Language

The UI ships in **English and Russian**. Switch it live under **Settings → Language** in the main
window — the whole interface updates instantly, with no app restart. On first launch the language
follows your system preference (Russian → Russian, otherwise English); your choice is then remembered.

## Project structure

```
devdeck/
├── DevDeck.xcodeproj
├── DevDeck/
│   ├── DevDeckApp.swift / AppDelegate.swift   # @main, LSUIElement, exit dialog, crash handlers
│   ├── Models/          # Command, Chain, Config, AppRef (Codable)
│   ├── Store/           # CommandStore (JSON load/save), ConfigCodec, FileWatcher
│   ├── Process/         # CommandRunner (protocol), Zsh/Sudo runners, ProcessManager (@Observable),
│   │                    # StreamingProcess, RingBuffer, AppController (quit/relaunch GUI apps)
│   ├── MenuBar/         # MenuBarController (NSStatusItem+NSPopover), PopoverView, TrayIcon, StatusIndicator
│   ├── MainWindow/      # MainWindowView, CommandEditorView, ChainEditorView, LogView, SettingsView
│   ├── Localization/    # LocalizationManager (live language switch) + L10n catalog (EN/RU)
│   ├── Diagnostics/     # DiagnosticLog (file log + crashes), SystemMemory (RAM/swap/pressure)
│   └── Resources/       # Assets.xcassets (tray glyph + AppIcon), default-config.json
└── DevDeckTests/        # state machine, chains, store, codec, memory, runners
```

Architecture details are in [`CLAUDE.md`](CLAUDE.md); the per-item plan and status are in
[`docs/PLAN.md`](docs/PLAN.md).

## Packaging a `.dmg`

```sh
./scripts/build-dmg.sh        # or: just dmg
```

The script: builds the Release `.app`, applies an **ad-hoc signature** (a stable code signature without
a Developer ID), stages it together with a symlink to `/Applications` (drag-to-install), and creates a
compressed `build/DevDeck-<version>.dmg` image via `hdiutil` (no external dependencies).

> Want a "pretty" dmg with a background and icon layout? Install
> [`create-dmg`](https://github.com/create-dmg/create-dmg) (`brew install create-dmg`) and replace the
> `hdiutil` call in the script — the staging layout is already compatible.

## Installing on another machine (unsigned)

The app is **not signed with a Developer ID and not notarized**, so Gatekeeper will block the first
launch ("DevDeck can't be opened because the developer cannot be verified" / "is damaged"). This is
expected. The target Mac must be on **macOS 15 (Sequoia)+**.

1. Copy `DevDeck-<version>.dmg` to the machine, open it, drag **DevDeck** into `Applications`.
2. Clear the quarantine one of these ways:
   - **Right-click `DevDeck.app` → "Open" → "Open"** (the dialog remembers the permission); **or**
   - in the terminal: `xattr -dr com.apple.quarantine /Applications/DevDeck.app`, then launch; **or**
   - launch it, get the rejection, then **System Settings → Privacy & Security → "Open Anyway"**.
3. The icon appears in the menu bar (it's not in the Dock — that's `LSUIElement`).

> The quarantine attribute is set **only when downloading via a browser/AirDrop**. If you move the dmg
> over `scp`/a flash drive, the quarantine-clearing step may not be needed.

## Minimum macOS

The deployment target is `15.0` (Sequoia); the app runs on macOS 15 and 26. Change it via
`MACOSX_DEPLOYMENT_TARGET` in `DevDeck.xcodeproj`. **The lower bound is `14.0`**: the code uses macOS 14+
API (Observation `@Observable`, `.focusEffectDisabled()`) and can't go below without changes.
After changing the target — run the tests.

## License

MIT — see [`LICENSE`](LICENSE).
