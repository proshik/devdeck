# Changelog

All notable changes to this project are documented in this file.
Format based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
versioning follows [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **Cluster health indicator**: a colored "Cluster: Healthy / Degraded / Down" line in the popover
  (colima `list --json` status + `minikube status`), refreshed while the popover is open; toggle in
  Settings (default on).

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
