# Stage 5 — Exit Dialog + Default Config

Date: 2026-06-07. Status: approved, ready for implementation planning. Closes MVP.

## Context

Stages 0–4 are complete (74 tests). `ProcessManager` already exposes `aliveDaemons`/`hasLiveDaemons`.
`CommandStore.start()` copies `defaultConfigData` on first launch (if `config.json` is absent),
but the app currently passes `nil` → the default is not shipped. This stage adds: (1) an exit
dialog when live daemons are running; (2) a real `default-config.json` for myproject and its wiring.

## Decisions (approved with the user)

- Exit dialog: "Kill / Leave in Background / Cancel" (native `NSAlert`).
- Two port-forward daemons: `svc/myproject-keycloak 30090:8080` and `svc/management-ui 8080:3000`
  (both `--context minikube -n myproject`).
- `sudo purge` stays in the default (will trigger the native password dialog — the first live sudo check).
- `appsToQuit` in the default are empty (the user will add memory-hungry apps in the editor).
- myproject: `/Users/proshik/dev/myproject` (workdir for `just dev-*`).

## Architecture

```
AppDelegate.applicationShouldTerminate(_:) -> .terminateNow / .terminateCancel
  hasLiveDaemons? -> NSAlert (Kill/Leave/Cancel) -> action
AppDelegate.store = CommandStore(defaultConfigData: <bundled default-config.json>)
DevDeck/Resources/default-config.json   (synced group places it in .app)
```

## Components

### Exit dialog (`AppDelegate`)
```swift
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard manager.hasLiveDaemons() else { return .terminateNow }
    // NSAlert: 3 buttons
    switch alertChoice {
    case .killDaemons:  manager.aliveDaemons.forEach { manager.stop($0) }; return .terminateNow
    case .leaveRunning: return .terminateNow                       // daemons are reparented to launchd
    case .cancel:       return .terminateCancel
    }
}
```
- "Kill": `stop()` sends SIGTERM synchronously before `.terminateNow` → the port is released.
- "Leave in Background": just quit, child `kubectl port-forward` processes keep running.
- Testable seam: the mapping (hasLiveDaemons, choice) → action is trivial; `aliveDaemons`/
  `hasLiveDaemons` are already covered. The `NSAlert` and the sudo password dialog are verified by running.

### Default config (`DevDeck/Resources/default-config.json`)
Commands: colima stop; `colima start --cpu 6 --memory 10 --disk 100`; minikube stop;
`minikube start --memory=6144 --cpus=4`; `sudo purge` (needsSudo); `just dev-start minikube seq`
and `just dev-build minikube seq` (workingDirectory = myproject); two port-forward daemons (isDaemon).
Chain "Full Restart": colima stop → colima start → minikube stop → minikube start → dev-build (stopOnError).

### Default wiring (`AppDelegate`)
```swift
let store = CommandStore(defaultConfigData:
    Bundle.main.url(forResource: "default-config", withExtension: "json").flatMap { try? Data(contentsOf: $0) })
```
On a clean machine (no `config.json`) the first launch writes the myproject default; otherwise leaves
the existing config untouched. To verify, delete the current `config.json`.

## Testing

- **Bundled default validity**: load `default-config.json` from the bundle (in a hosted test
  `Bundle.main` = DevDeck.app), `ConfigCodec.decode` without error, verify the presence of commands,
  two daemons (isDaemon), a sudo command (needsSudo), and the "Full Restart" chain. Closes the
  "broken bundled default" risk from Stage 1.
- Exit dialog/sudo password dialog — verified by running the app against a checklist in the plan
  (daemon alive → quit → "Leave" → `lsof` shows port-forward; "Kill" → port free; `sudo purge` → password dialog).

## Out of Stage 5 (beyond MVP)

- Adopting a daemon by PID after restart (`state.json`), hotkeys, login autostart (`SMAppService`),
  cluster health indicator in the menu bar icon.

## Risks / Notes

- `sudo purge` under `osascript` runs in `sh` (not zsh) — PATH doesn't matter for `purge`.
- "Kill": SIGTERM is sent synchronously, but the process dies asynchronously; the port is freed
  a moment after quit — acceptable.
- The first sudo dialog may require Automation/password; an LSUIElement app's dialog may appear
  behind other windows — if needed, bring the app to the foreground before showing `NSAlert`.
