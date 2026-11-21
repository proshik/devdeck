# DevDeck — next release (draft)

> Draft for the release after v0.22.1. `release.yml` still creates the GitHub release with
> `--generate-notes`; after a release, replace its body with
> `gh release edit v<VERSION> --notes-file docs/release-notes-next.md`.
> Not published until the user asks for a release.

DevDeck grows from a command deck into a control panel for the Mac you develop on. Commands,
daemons, chains, port-forwards and proxies work as before; everything new is off until you turn
it on.

## New

- **Redesigned panel and settings.** The menu bar panel has tabs for Environment, Monitoring,
  Displays and Clipboard. Under *Panel & Modules* you can add your own tabs, reorder and hide
  modules by drag and drop or from the context menu, and restore the standard layout. Hiding a
  module never stops the service behind it. Settings are split into General, feature pages and
  *DevDeck Updates*.
- **Clipboard history.** Text, images and copied files, with search, type filters, pinning, pause,
  per-app exclusions and limits on count, age and size. Content marked as concealed or transient
  (password managers) is skipped. History is stored privately (0600 files, 0700 directory). It can
  also paste into the app you came from; that needs Accessibility, and copying works without it.
- **Display brightness.** A slider for each display: Apple displays natively, compatible external
  monitors over DDC/CI, and an explicit software-dimming mode. The MacBook brightness keys can
  control the display under the cursor, with a compact on-screen indicator. At 0% an external
  monitor goes black without powering off, so the connection and USB-C charging stay up. Displays
  with a known luminance range show an approximate nits value.
- **Monitoring.** CPU, memory, swap, disk and uptime; container VM, minikube and cluster state
  (colima); battery, adapter and power. Each has its own on/off switch, sampling interval and
  bounded history graph. Values a sensor cannot provide show as unavailable, never as zero.
- **Network.** Traffic of the selected interface, with a graph and per-session totals, plus a
  manual internet speed test (`networkQuality`) that you can cancel. Opening the panel never
  starts a speed test.
- **Automation.** `DevDeck automation list|run|stop|status|brightness` controls saved commands,
  chains and display brightness from a terminal, a script or a coding agent
  (`/Applications/DevDeck.app/Contents/MacOS/DevDeck automation help`). Automation is off by
  default, and only commands and chains you mark "Allow from Shortcuts" are reachable. Shortcuts
  actions are included too, but macOS runs them only for apps signed with a Developer ID, which
  this build is not.
- **Permissions page.** Shows the real state of every permission DevDeck uses (Accessibility,
  pasteboard access, notifications, Automation of Ghostty, local network, open at login), which
  features need each one, and a link to System Settings. DevDeck asks for a permission only when
  you turn on a feature that needs it. Notifications are now asked for the first time you run a
  command, not at every launch.
- **Crash recovery.** If DevDeck quits unexpectedly twice during the same operation (agent tab
  restore, container probes, display discovery, an update install), or three times in a row
  shortly after launch, it switches off the affected additional modules. Commands, daemons and
  proxies keep running. A banner and the *Recovery* section of the permissions page say what was
  switched off and why, and turn it back on. Your settings, `config.json` and the agent-tab
  snapshot are never changed by recovery.

## Changed

- The menu bar icon is a plain template glyph. Engine and memory-pressure state appear only in
  the panel.
- When `config.json` has an error (for example, an unfinished hand edit), DevDeck no longer
  writes over it: changes from the UI are not saved, and the banner says so until the file is
  fixed.

## Upgrading

- A `config.json` from v0.22.x is read without losing any value. New settings get defaults, and
  `schemaVersion` is unchanged.
- macOS ties Accessibility to the exact app binary. If brightness keys or paste stop working after
  the update, remove DevDeck from *Privacy & Security → Accessibility* and add it again.
