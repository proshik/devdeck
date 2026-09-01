# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **Session history on the Agent tabs page, and reopening one tab at a time.** The page used to
  mirror only what was open, so a tab closed an hour ago was gone from it. It now also lists the
  sessions both agents remember from the last 7 days — across every project, newest first, with a
  search over title and directory — and every row carries a button that reopens just that one, in
  its own directory, without touching the reboot snapshot. A row whose session is already open
  offers nothing, since reopening it would only create a duplicate tab.

  The window is 7 days for a measured reason: a transcript older than it is skipped without being
  opened at all, which on a real machine is the difference between reading 270 MB and 1.1 GB. What
  is read is remembered in `agent-sessions.json` (owner-only, beside the other files this app
  writes), keyed by file and modification time, so the seconds a first build costs are paid once
  rather than at every launch.

### Fixed
- **The Cleanup page promised 341 MB where 27 GB were waiting.** The estimate beside "dead
  containers" was docker's own `Reclaimable` column, which answers a different question: what is
  unreferenced *right now*. An anonymous volume is still linked by the exited container that
  created it, so a backlog of testcontainers postgres leftovers counted as nothing — while the
  named dangling volumes docker did count are exactly the ones `docker volume prune` spares
  without `-a`. The probe now also reads the per-volume listing and the volumes running containers
  hold, and the estimate sums the anonymous volumes only stopped containers keep alive: the action
  prunes those containers first, so the volumes are free by the time it reaches them. The figure
  moves both ways — on the machine this was measured on it went from 341 MB to 26.7 GB on colima,
  and from 1.4 GB down to 177 MB inside minikube, where the gigabyte docker had been counting sits
  in a named cache the button never deletes. A daemon whose listing doesn't parse falls back to
  docker's figure rather than reporting zero. The verbose pass costs a second disk walk, so a
  refresh is now seconds rather than milliseconds on a full disk.

  The page around it was rearranged to answer one question — where the disk actually went. Each
  daemon's categories are listed biggest first; a row states what it occupies and nothing else,
  since the number beside the button now says what that button frees and the two used to
  contradict each other in plain sight. The colima volumes row breaks itself down into the two
  things that fill it: the `minikube` volume (the node's entire disk, the box below — the two
  boxes were silently counting the same 42 GB twice) and the anonymous volumes stopped containers
  still hold. Above 85% the disk bar now says what that costs — BuildKit pruning its cache
  mid-build, minikube's kubelet reacting to nothing because image GC and eviction are off in it —
  and the build-cache confirmation admits the disk frees up less than the cache's size, the
  layers shared with images staying behind them.
- **A remote proxy could not be edited, only deleted and recreated.** `ProxyManager` already had
  `saveRemoteProxy`, but no screen called it — a typo'd SSH destination meant starting over. The
  edit sheet described under Added below reuses it; saving a live pair used to silently never
  relaunch (a stale `states[]` read right after `stopRemote()` made the restart skip the relaunch
  entirely), which is now fixed alongside it.
- **Editing the host share while it was live silently killed it for good.** The exact same
  stale-`states[]` defect just fixed in `saveRemoteProxy` above was also sitting in `saveShare`
  (`stopShare()` then `startShare()`) — changing the share's port, auth or engine while it was
  running stopped the listener and then read its own not-yet-updated "already up" state back,
  so the restart never happened and nothing came back short of toggling Share off and on.
  `startShare` now takes the same `forceRestart` parameter `startRemote` already had, and
  `saveShare` passes it.
- **Deleting a remote proxy lived only in a right-click menu.** The action existed
  (`deleteRemoteProxy`, with or without its tunnel command) but nothing on the row hinted at it —
  exactly the kind of invisible affordance that gets reported as a missing feature. Each row now
  also carries visible pencil/trash buttons; the context menu stays for whoever already used it,
  and now asks the same confirmation the trash button does rather than deleting immediately.
  Deleting the linked tunnel command remains a separate, explicit choice in the confirmation
  dialog, never a side effect of deleting the proxy.
- **"Check" did nothing when a remote proxy's route was down.** The popover's check button
  resolves the active proxy first and does nothing at all if that fails — for a remote proxy that
  happens whenever the SSH tunnel or the local bridge isn't up, which used to look exactly like a
  hang. The check row now reports which half is missing (no active proxy, tunnel down, bridge
  down, or both), the same way a failed probe already reports "no response".
- **"VM minikube" was blank almost always.** The node probe only runs while a command is
  building, but the 1 s sampler also runs for as long as any daemon is alive — and it wrote an
  empty value into the line on every tick, so with a port-forward up the figure never showed.
  The sampler now touches the line only when it actually probed, and the popover refreshes it
  every 15 s while open (one `minikube ssh`), alongside the cluster and disk probes.
- **A hairline through the traffic lights.** Any window with a toolbar gets AppKit's automatic
  titlebar separator, and on macOS 26 the toolbar metrics put that line at the height of the
  close/minimise/zoom buttons — it looked like a rendering glitch cutting the buttons in half.
  The main window now sets `titlebarSeparatorStyle = .none`; it separated nothing (the sidebar
  keeps its own divider above the pinned Proxy/Settings buttons).

### Added
- **Editing a remote proxy.** The Proxy page's remote (SSH) proxies gained an edit sheet — name,
  local/SOCKS ports, and the SSH destination, prefilled by parsing it back out of the tunnel
  command. The destination lives inside that command, and the command is a normal, user-editable
  deck command, so an edit is only written back into it when the command is still exactly what the
  generator would have produced for the proxy's previous values (`TunnelCommandUpdate.plan`, a
  pure decision with its own tests); if the user has hand-edited the command since — a jump host,
  `-o ServerAliveInterval`, an identity file — the sheet leaves it untouched, says so, and offers a
  button straight into the command editor instead of guessing. A safe SOCKS-port edit now also
  updates the tunnel command's own `Command.port` (the occupied-port precheck and the watchdog's
  post-crash recheck key off that field, not the command string) — a hand-edited command's `.port`
  is deliberately left alone, since we no longer know which port that command actually uses.
- **Claude Code tabs restored after a reboot.** With "Restore tabs after a restart" enabled in
  Settings, DevDeck watches Ghostty's open tabs and, on a timer, captures each one's working
  directory and — by matching the tab title against the project's transcript files — the Claude
  Code session it belongs to, where one can be resolved. On the first Ghostty launch after a real
  reboot (told apart from an ordinary Ghostty restart by comparing the machine's boot time), each
  captured tab reopens in its directory over AppleScript and runs `claude --resume <id>` when a
  session was found; a tab whose session could not be resolved still comes back, as a plain shell
  in the right directory, rather than being dropped. The popover's new "Agent tabs" section shows
  the last snapshot at a glance with "Capture now" / "Restore now" buttons, and a matching page in
  the main window lists every tab with its directory and whether it will resume its session or
  restore the directory only.
- **opencode joins Claude Code in tab restore.** The tab-restore feature now recognizes opencode's
  own Ghostty tabs — titled `OC | <session title>` — alongside Claude Code's, resolving each to its
  own agent's session (via `opencode session list --format json`, cached per directory for a
  minute) and reopening it after a reboot with `opencode --session <id>`, the same way a Claude tab
  reopens with `claude --resume`. The main window's tab table gained an **Agent** column showing
  which agent a tab resolved against; a tab whose session cannot be identified still comes back as
  a plain shell in its directory, whichever agent it belongs to.
- **What the metrics mean.** Every cell in the popover header (Memory, Swap, Cluster, VM colima,
  VM minikube, Pressure, VM disk, Swap rate, CPU load) now carries a tooltip explaining what the
  figure measures, where it comes from and what a bad value means; the same texts sit under
  Settings → Memory monitoring → "What the metrics mean" for reading without hovering.
- **Cleanup page** — a pinned sidebar entry next to Proxy/Settings that shows where the colima
  disk goes (`docker system df` for the VM's own docker *and* for the docker inside the minikube
  node, where `minikube docker-env` builds and the cluster's images live) with one button per
  reclaimable category: dead containers plus their anonymous volumes (testcontainers leftovers),
  the BuildKit cache, and unused images. Each button confirms with docker's own reclaimable
  estimate and runs through the normal runner, so its output lands in Logs. Named volumes and
  running containers are never touched; the images button warns about `imagePullPolicy: Never`.
  A **Restart colima** button (followed by `minikube start`, the node container does not come back
  on its own) covers the one thing that actually returns VM memory to the Mac. A trash icon in
  the popover footer (orange past 85%) and the "VM disk" cell open the page, and past 85% an
  orange hint line appears under the metrics —
  minikube's kubelet ships with image GC and eviction disabled, so nothing else will react before
  the disk hits 100%.
- **Remote proxy (VDS over SSH)** — route flagged commands through a VDS reachable over SSH, with
  nothing installed on it but `sshd`. DevDeck holds an `ssh -N -D` dynamic-SOCKS tunnel (created as
  a regular, editable deck command) plus a local **bridge** — the built-in engine dialing targets
  through that SOCKS upstream — and presents the pair as an ordinary `http://127.0.0.1:<port>`
  proxy. Hostnames are resolved on the VDS (SOCKS domain addresses), so blocked domains resolve
  where they work. Selectable alongside LAN proxies on the Proxy page; held up while selected
  (watchdog + across app restarts). Config: `remoteProxies` + `settings.activeRemoteProxyID`
  (mutually exclusive with the discovered selection).
- **Browser via proxy** — a button on the Proxy page opens a separate Chrome instance that egresses
  through the active proxy, with its own profile, without touching the default browser. Fills the
  browser half of OAuth logins like Claude Code's `/login`: the page loads through the proxy while
  the `localhost` callback stays direct. Works for LAN and remote proxies alike.

### Changed
- **"VM colima" now measures memory used inside the VM** (`MemTotal − MemAvailable` from the
  guest's `/proc/meminfo`, one `colima ssh` per sample) instead of the hypervisor's footprint on
  the Mac. With lima/vz the guest's page cache stays resident in the host process for good — no
  balloon deflate, no free-page reporting — so the old number climbed to ~100% after the first big
  build and never came back, and the per-run peak and the 90% warning were noise. The new figure
  has the same meaning as the minikube line, and the `colima --memory` hint in the run summary
  is grounded again. Host-side effects remain visible in Pressure / Swap.
- The per-command flag is now **"Route through the active proxy"** (was "Route through the LAN
  proxy"). Behaviour is unchanged — the old wording made the remote/VDS proxy look unsupported.
- The `dp` shell helper honors a network-independent scope (`DEVDECK_PROXY_LAN=*`) for loopback
  (remote) proxies — **re-paste the snippet** from the Proxy page if you use `dp`.

### Added (earlier this cycle)
- **Built-in proxy engine** — the share side no longer needs `gost`: an in-process HTTP listener
  (`Network.framework`, CONNECT + absolute-form, optional Basic auth from the Keychain) serves the
  share by default. A new **Engine** picker on the Proxy page chooses between **Built-in** and
  **gost (system)**; `gost` remains only for peers that need SOCKS. The engine is stored as
  `proxy.engine` in config.json (`"builtIn"` / `"gost"`, absent = built-in — **existing configs
  switch to the built-in engine on update**; SOCKS users: pick gost back in the editor). From the
  outside nothing changes: the same synthetic daemon in the popover (watchdog, occupied-port
  panel), the same Bonjour announcement (TXT `proto` now says `http` for the built-in engine), the
  same connected-clients list, fed by the listener's own gost-shaped session lines. Quitting the
  app never offers to keep the built-in listener "in background" — an in-process listener dies
  with the app and comes back on the next launch by itself.
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
- **Connected machines on the Proxy page**: the share side now shows who is actually using it —
  parsed straight out of the `gost` listener's own log stream (no new process, no new port). Each
  peer is named by reverse DNS where possible, falls back to its bare IP otherwise, and shows a
  green dot + live-session count while active or a "N min ago" caption once it goes quiet; the list
  itself survives a watchdog restart, and only switching the share off clears it. A matching
  `connected N` segment appears in the popover's announcement line, counting active peers only.
  Read-only: no traffic counters, no destination hosts, no way to kick a client.
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
