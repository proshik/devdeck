# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **Proxy Manager** — share one Mac's VPN egress with another over the LAN, without copying IP
  addresses by hand or touching the system proxy:
  - **Share side**: supervises a `gost` listener (HTTP+SOCKS on one port) as a synthetic daemon, so
    it inherits the existing engine — watchdog auto-restart, orphan adoption, occupied-port panel.
    Optional `user:pass`; the password lives in the Keychain, never in config.json.
  - **Announcement**: published over Bonjour (`_devdeck-proxy._tcp`) with a TXT record carrying
    host/port/auth and the VPN exit IP (resolved through the proxy itself, proving the tunnel is
    live). Driven by the listener's state, so watchdog restarts re-announce automatically and a dead
    proxy is never advertised. The announced address is always a physical `en*` interface — never the
    VPN tunnel, which no peer could reach.
  - **Client side**: browses the LAN and lists what it finds; pick one as active by its Bonjour name,
    so the peer's IP can change freely without reconfiguration. The active proxy's last known address
    is remembered, so it keeps working on networks that filter multicast (every corporate VPN) and
    silence the announcement while the proxy itself stays reachable — the row remains in the list,
    dimmed, captioned "Last known address — not announced right now". That address is scoped to the
    LAN it was learned on (never used after moving to another network), ignored while discovery is
    off, and cleared when the proxy is deselected.
  - **Routing**: a new "Route through the LAN proxy" flag per command injects `HTTPS_PROXY` & co
    (both cases, plus `ALL_PROXY`/`NO_PROXY`) into that process only. With no usable proxy the run
    fails explicitly instead of silently going direct — the flag exists to prevent exactly that leak.
  - New "Proxy" page in the main window, a Proxy section in the popover, and two toggles in Settings.
- **Run through the proxy from anywhere**: a `dp` shell function (copy it from the Proxy page into
  `~/.zshrc`) routes any command through the active proxy from whatever directory you're in —
  `dp claude`. It reads `~/.config/devdeck/proxy.env`, which DevDeck keeps in step with the app's
  own routing verdict, and refuses to run when that proxy is not on the current network. Note the
  trade-off: a shell cannot read the Keychain, so if the active proxy needs a password that file
  holds it in plain text — owner-only (mode 0600), written in place so it is never briefly
  world-readable, and deleted as soon as the proxy is deselected. The Proxy page says so next to
  the snippet. For runs from the deck, a new "Ask for a directory on every run" flag lets one
  command serve every project — the directory is chosen at launch and never saved.
- **Daemon watchdog (auto-restart)**: a shield toggle on daemon rows in the popover — starts the
  daemon and restarts it automatically if it dies (3 attempts with 2/3/5 s pauses; a stable run
  resets the counter; give-up turns the shield red + notification). The flag persists in
  config.json and survives app restarts — adopted daemons re-arm and are watched by PID polling.
  A manual Stop never triggers a restart.
- **Occupied-port detection**: a new optional "Local port" field on commands (auto-filled from
  `port-forward`/`-L`/`--port`/`-p` syntax while editing). Before starting a daemon the port is
  checked via `lsof`; if a foreign process holds it, an inline panel in the popover offers
  "Kill & start" (SIGTERM → SIGKILL escalation, then launch) or "Cancel". A fast startup failure
  also triggers the check (covers chain steps). The watchdog pauses on a conflict instead of
  burning restart attempts.
- **Cluster health indicator**: a colored "Cluster: Healthy / Degraded / Down" line in the popover
  (colima `list --json` status + `minikube status`), refreshed while the popover is open; toggle in
  Settings (default on).
- **Appearance mode** in Settings: Light / Dark / System (applied app-wide via `NSApp.appearance`,
  persisted in UserDefaults).
- **Terminal tabs can stay open.** A per-command "Stay in the shell after the command finishes"
  option hands the tab over to an ordinary shell in the same directory instead of closing it, so a
  command can be re-run by hand or its output read at leisure.
- **Any terminal, not just Ghostty.** A third launch mode, "Custom command", runs a command line you
  supply with `{script}` substituted — `wezterm start -- {script}`, `open -a iTerm {script}`, and so
  on. Ghostty keeps working with no configuration.

### Changed
- Main window sidebar: Settings is pinned to the bottom (always visible, separated by a divider)
  instead of scrolling at the end of the commands/daemons/chains list; "Proxy" is pinned next to it.
- Taller, slightly narrower menu bar popover (360×560 → 380×675).
- Config schema 1 → 2 (`proxy` block, proxy settings, `routeThroughProxy`). Existing files load
  unchanged — every new key decodes to its default rather than going through a migration.

### Fixed
- Define the `AccentColor` asset so control on-states (Settings toggles) are visible in dark mode.
- Terminal run directories are no longer deleted the moment a command finishes or its startup times
  out — the timeout deletion could remove the script of a terminal that was merely slow to start,
  and keeping `run.zsh` beside a live tab makes a misbehaving command diagnosable. They are swept at
  the next launch instead, once their terminal is gone.

### Security
- **The proxy share password no longer travels on the command line.** It used to be part of the
  listener spec (`gost -L 'auto://user:pass@:9999'`), and macOS lets every local account read the
  full argv of every process — root's included — so the password was effectively published to the
  machine. The whole service definition moved into a generated `gost.json` (mode 0600, beside
  config.json) and the command line carries nothing but its path. Closes the deferred risk recorded
  in `docs/proxy-manager-plan.md`.
  - A password containing `'` used to close the shell literal and run the rest of it as commands.
    The config is generated with `JSONEncoder`, so the escaping is no longer hand-rolled and the
    injection is structurally impossible.
  - Upgrading with a listener already running: the occupied-port panel appears once, and
    "Kill & start" is the intended path through it.
- **`config.json` and `devdeck.log` are owner-only (0600), in an owner-only directory (0700).** They
  were 0644 in a 0755 directory, readable by every other account on the Mac — while `proxy.env`
  right next to them was carefully kept at 0600. config.json describes every command this user runs
  and where; the log names every command, proxy and path involved. Existing installs are migrated on
  the next launch, not only on the next save, and a rotated `devdeck.log.1` is tightened too.
- One implementation of shell quoting instead of four copies, and the private-file writer now opens
  with `O_NOFOLLOW`, so a symlink planted at `proxy.env` or `gost.json` cannot redirect a write that
  may carry a password.

## [0.3.0] — 2026-06-20

### Added
- **Launch at login** (`SMAppService`) — toggle in the new "Startup" settings section.
- **Global hotkey ⌃⌥D** to open/close the deck from anywhere (Carbon `RegisterEventHotKey`,
  no Accessibility permission); opt-in toggle in "Startup".
- **Tier 1 — Host memory monitoring** (toggle in Settings, default on):
  - Memory pressure level (normal / warning / critical) displayed as a colored badge on the menu bar icon
    (polled from `kern.memorystatus_vm_pressure_level`, refreshed on a timer).
  - Per-run build-process peak RSS written to the diagnostic log together with a pressure + compressor summary.
  - OOM / SIGKILL detection: `terminationStatus == 9` + regex over the log tail extracts the offending crate
    name and records it to the log.
  - `-j` vs RAM-limit advisory in the command editor (rule: `limit_GB / 2` per rustc job), now grounded
    in live colima cpus/limit (parsed from `colima list --json`) with a fallback to conservative defaults.
  - Compressor saturation shown in the popover (`host_statistics64 compressor_page_count`).
  - Live swap rate (out ↑ / in ↓) shown in the popover during a run — distinguishes
    "full but stable" from "actively thrashing"; computed from consecutive `host_statistics64` samples.
- Proactive high-memory warning: a banner + log entry when colima or minikube cross 90% of their
  memory limit during a run (debounced to once per layer per run).

### Changed
- Host per-run log line renamed "Host peak" → "Host summary" and no longer prints a misleading
  "build RSS 0.0 GB" for nested builds (rustc runs inside the VM, invisible to the host).
- Pressure level shown in the popover as a right-aligned colored value (orange = warning, red = critical).
- Menu bar pressure-dot position derives from the glyph size instead of a hardcoded offset.

## [0.2.0] — 2026-06-11

Memory monitoring for heavy Rust builds — both tiers.

### Added
- **Tier 1 — colima memory from the host:** live "VM colima X / 10 GiB · %" line in the popover
  (hypervisor RSS vs. limit from `colima list`), peak per run logged with a hint about
  `colima --memory`; toggle in the new "Settings" section of the main window.
- **Tier 2 — minikube memory from inside the VM:** ssh probe reads anon memory of the node
  (`memory.stat`) against its actual limit (= `minikube --memory`), counts concurrent `rustc`
  processes and their total RSS. "VM minikube" line in the popover during a run; peak + rustc
  maximums logged with a hint about `minikube --memory`.
- **OOM detection after a failed run:** kubectl scan of pods for `OOMKilled` +
  `dmesg | grep oom` inside the node — victims logged.

### Fixed
- Probes/shell calls are strictly off the main thread (UI freeze on colima restart).
- Sampler now covers terminal chains; ssh probe does not hammer when daemons are hanging
  without an active build; under XCTest the diagnostic log goes to a temp directory.

## [0.1.0] — 2026-06-08

First MVP — complete local dev cycle from the menu bar.

### Added
- Menu bar icon (`NSStatusItem`) with a custom glyph (mixer/faders) on all monitors.
- Minimalist popover control deck: **Commands / Daemons / Chains** sections, collapsible,
  with active-item counters and state persistence.
- Command launch/stop via `/bin/zsh -lc` (PATH from `~/.zshrc`), status indicators.
- Daemons (long-lived processes) with a persistent indicator; exit dialog
  "Kill / Leave in Background / Cancel".
- Command chains — sequential, stop on error, failed step highlighted.
- sudo commands via the native macOS password dialog.
- Main window: command editor, chain builder (drag-and-drop), live logs.
- Memory freeing: graceful-quit of memory-hungry GUI apps before a command and relaunch after.
- Popover header with memory: RAM (used/total/%), swap on a separate line, color-coded by pressure,
  auto-refreshed every second.
- Diagnostic log + crash reports; "Log" button opens the file in Finder.
- JSON config (`~/Library/Application Support/DevDeck/config.json`) with FileWatcher and
  safe handling of malformed JSON; initial `default-config.json` with examples.
- `.dmg` packaging script (`scripts/build-dmg.sh`).

[Unreleased]: https://github.com/proshik/devdeck/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/proshik/devdeck/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/proshik/devdeck/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/proshik/devdeck/releases/tag/v0.1.0
