<div align="center">

# DevDeck

**A native macOS menu bar control deck for your local dev commands and background daemons.**

Launch, stop, and monitor local dev commands and long-running daemons
(`colima`, `minikube`, `just`, `kubectl port-forward`, …) — without the chore of juggling terminals.

[![Tests](https://github.com/proshik/devdeck/actions/workflows/tests.yml/badge.svg)](https://github.com/proshik/devdeck/actions/workflows/tests.yml)
[![Coverage](https://img.shields.io/endpoint?url=https%3A%2F%2Fraw.githubusercontent.com%2Fproshik%2Fdevdeck%2Fbadges%2Fcoverage.json)](https://github.com/proshik/devdeck/actions/workflows/tests.yml)
[![Release](https://img.shields.io/github/v/release/proshik/devdeck?logo=github&color=1575F9)](https://github.com/proshik/devdeck/releases/latest)
[![Downloads](https://img.shields.io/github/downloads/proshik/devdeck/total?color=2EA043)](https://github.com/proshik/devdeck/releases)

[![Platform](https://img.shields.io/badge/platform-macOS%2015%2B-1575F9?logo=apple&logoColor=white)](#requirements)
[![Swift](https://img.shields.io/badge/Swift-5-F05138?logo=swift&logoColor=white)](https://swift.org)
[![UI](https://img.shields.io/badge/UI-SwiftUI%20%2B%20AppKit-1575F9)](#stack)
[![Languages](https://img.shields.io/badge/i18n-EN%20%2F%20RU-2EA043)](#language)
[![Dependencies](https://img.shields.io/badge/dependencies-Sparkle%20only-2EA043)](#stack)
[![Homebrew](https://img.shields.io/badge/homebrew-proshik%2Ftap-FBB040?logo=homebrew&logoColor=white)](#homebrew-recommended)
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
- **Cleanup page** — where the colima disk goes (`docker system df` for the VM and for the docker
  inside the minikube node) with one confirm-first button per reclaimable category, and a colima
  restart for when the VM's page cache has eaten the Mac. The popover points at it past 85%.
- **Proxy Manager** — share this Mac's VPN egress with another machine over the LAN: a built-in
  HTTP proxy listener announced over Bonjour, and a per-command "route through the LAN proxy"
  flag on the client side. Works out of the box; an alternative
  [`gost`](https://github.com/go-gost/gost) engine covers SOCKS clients
  (see [Requirements](#requirements)).
- **Remote proxy (VDS over SSH)** — no second Mac needed: route flagged commands through a VDS
  reachable over SSH. Nothing runs on the VDS but `sshd` — DevDeck holds an `ssh -N -D` tunnel plus
  a local bridge and presents it as an ordinary `http://127.0.0.1` proxy.
  See [Remote proxy over SSH](#remote-proxy-over-ssh).
- **Browser via proxy** — one click (in the popover or on the Proxy page) opens a separate Chrome
  window that egresses through the active proxy — LAN or remote — with its own profile and without
  touching your default browser. This is what makes browser logins like Claude Code's `/login`
  work: the page loads through the proxy while the `localhost` callback stays direct.
- **Diagnostics** — a file log + crash reports; the "Log" button reveals `devdeck.log` in Finder.
- **JSON config**, editable both by hand and from the UI; external edits are picked up by a FileWatcher,
  broken JSON → an error in the UI while the last valid version is kept in memory.
- **Bilingual UI (EN / RU)** — switch the interface language live in Settings, no restart required.
- **In-app auto-update (Sparkle)** — get new versions automatically, or see when one is available.

## Install

### Homebrew (recommended)

```sh
brew install --cask proshik/tap/devdeck
```

This adds the [`proshik/tap`](https://github.com/proshik/homebrew-tap) tap automatically and installs
the latest release. The icon appears in the menu bar (no Dock icon — it's an `LSUIElement` app).

- **Homebrew 6.0+** asks you to trust a third-party tap once. If you see "untrusted tap", run
  `brew trust proshik/tap` and re-run the install.
- **First launch — Gatekeeper.** DevDeck is **not notarized** (free distribution), so Homebrew
  quarantines the download and macOS blocks the first launch. Clear it once:

  ```sh
  xattr -dr com.apple.quarantine "$(brew --prefix)/Caskroom/devdeck"/*/DevDeck.app
  ```

  (or right-click `DevDeck.app` → **Open** → **Open**). You only do this once.

### Updating

Updates are delivered **in-app via Sparkle** — no `brew upgrade` needed (the cask is
`auto_updates`). In **Settings → Updates**:

- **Automatic on** → new versions download and install themselves;
- **Automatic off** → the popover shows a small ⤓ indicator with "current → latest (N behind)";
  click it to update.

Sparkle-installed updates are not quarantined, so the first-launch step above is never repeated.

### Uninstall

```sh
brew uninstall --cask proshik/tap/devdeck
brew untap proshik/tap          # optional: remove the tap too
```

### Without Homebrew

Grab the `.dmg` from [Releases](https://github.com/proshik/devdeck/releases) and follow
[Installing on another machine](#installing-on-another-machine-unsigned) below.

## Requirements

- **macOS 15.0 (Sequoia)+** — the target minimum (deployment target); also runs on macOS 26 (Tahoe).
  It can't go below 14.0 — the code uses macOS 14+ API (`@Observable`, `.focusEffectDisabled()`).
- **Xcode 16+** to build.
- Optional: [`just`](https://github.com/casey/just) — for the short commands in the `justfile`.
- Optional: [`gost`](https://github.com/go-gost/gost) (`brew install gost`) — only for the **gost
  engine** of the proxy share (the Proxy page), i.e. when a peer needs SOCKS. The default
  **built-in engine** serves HTTP (CONNECT) with no external dependency — enough for every DevDeck
  client and the `dp` helper. DevDeck looks for gost at `/opt/homebrew/bin/gost` or
  `/usr/local/bin/gost`; with the gost engine selected and no binary the share can't start (the
  editor shows a warning).

## Stack

- **Language:** Swift, UI in SwiftUI + AppKit (`NSStatusItem`, `NSPopover`).
- **Build:** an Xcode project (`DevDeck.xcodeproj`) — produces the `.app` bundle, `Info.plist`, icon,
  and live previews out of the box; the path to eventual distribution (Mac App Store / notarization).
- **`Info.plist`:** `LSUIElement = true` (no Dock icon, menu bar only). No sandbox — it needs to launch
  external processes and reach arbitrary working directories.
- **One third-party dependency:** [Sparkle](https://sparkle-project.org) (in-app updates), pulled in
  via SwiftPM. Nothing else — no networking, UI or utility libraries.

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

## Remote proxy over SSH

When there is no second Mac to share from, egress through a **VDS** reachable over SSH — a server in
a region where the services you need are available. Nothing is installed on the VDS: it needs only
`sshd`. DevDeck holds an `ssh -N -D` dynamic-SOCKS tunnel and a local **bridge** (the built-in
engine dialing through that SOCKS), presenting the whole thing as an ordinary
`http://127.0.0.1:<port>` proxy. Hostnames are resolved on the VDS, not locally.

### Before you start

DevDeck runs `ssh` as a background daemon — **with no terminal attached**. Anything ssh would
normally ask a human cannot be answered, so it must already be settled:

- **Key-based auth, no passphrase prompt.** A password login, or a key whose passphrase is not in
  the agent, leaves the tunnel dead on arrival. Use a key and make sure the agent holds it
  (`ssh-add -l`); on macOS, `UseKeychain yes` in `~/.ssh/config` makes that survive reboots.
- **The host key must already be trusted.** The first connection to an unknown host asks
  "Are you sure you want to continue connecting?" — nobody is there to type `yes`.
- **`AllowTcpForwarding` must be on at the VDS** (sshd's default, but hardened images disable it).
  Without it the tunnel connects and then forwards nothing, which looks like "everything is up but
  nothing works".

One check covers all three — run it in a terminal once. It must finish instantly, printing nothing
and asking nothing:

```sh
ssh <your-host> true          # silence = ready; any prompt = fix it before adding the proxy
```

No software is installed on the VDS and no root is needed there — an ordinary account with `sshd`
is the whole requirement.

### Setting it up

1. **Proxy page → Remote proxies (SSH) → Add remote proxy…** — give it a name and an SSH
   destination (a host from `~/.ssh/config`, or `user@host`). The local HTTP port (18888) and SOCKS
   port (1080) have sane defaults. DevDeck creates a regular, editable `ssh -N -D …` daemon command
   and links it — add `-J jumphost` or other options by editing that command later.
2. **Select it** in the list. DevDeck holds the tunnel and the bridge up (with watchdog restarts,
   and across app restarts) while it stays selected. The check button shows the VDS's public IP —
   proof traffic egresses there.
3. **Flag a command** with "Route through the active proxy", or use the `dp` helper from any
   terminal — `dp claude`.
4. **Browser logins** (`/login` in Claude Code): click **Browser via proxy**. It opens a separate
   Chrome window that egresses through the proxy, with its own profile, without touching your
   default browser. Paste the printed login URL there; the `localhost` callback stays direct and
   reaches the waiting CLI. A real Chrome means Google SSO and passkeys work normally.

> The `dp` snippet changed for this release (it now honors a network-independent scope). If you
> pasted an older one, re-copy it from **Proxy page → terminal helper**.

### When it doesn't work

The tunnel is an ordinary daemon in the deck, so it fails visibly: its row goes red and the
watchdog keeps retrying, and the proxy stays unusable (a flagged command fails loudly rather than
going direct). What the log — **"Log" button → `devdeck.log`** — will tell you:

| Symptom | Cause |
|---|---|
| Tunnel dies immediately, over and over | ssh wants something a daemon can't answer — see [Before you start](#before-you-start) |
| Tunnel stays up, the check button fails | `AllowTcpForwarding no` on the VDS, or the SOCKS port is taken locally |
| "Port 1080 is occupied" panel | something else holds the port — the panel offers to kill it, or change the port on the proxy |

To see the raw error, run the tunnel command by hand once: open it from the deck, or paste its
`ssh -N -D …` line into a terminal — there ssh can finally tell you what it wanted.

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
│   ├── Cleanup/         # docker system df probe, cleanup commands, CleanupModel
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
