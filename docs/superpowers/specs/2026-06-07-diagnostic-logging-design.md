# Diagnostic Logging (Events + Crashes)

Date: 2026-06-07. Status: approved, ready for implementation. Post-MVP feature.

## Context

MVP is complete (Stages 0–5, 75 tests). The app writes nothing to a log: when it "closed after
a button press", the cause had to be tracked down in system journals (and turned out to be a
normal "Quit", not a crash). We need **our own log file** — generous event logging during
operations + crash capture — so such cases are immediately visible.

## Decisions (approved with the user)

- Scope: **events + crashes**, log generously during operations.
- Path: `~/Library/Application Support/DevDeck/devdeck.log` (alongside the config).
- UI access: a **"Show Log"** button in the control deck footer.

## Architecture

```
DiagnosticLog (final class)  — thread-safe file logger + crash handlers
  .shared                    — singleton at the standard path; init(fileURL:) — for tests
  .log(_:level:)             — append timestamped line (serial queue)
  .installCrashHandlers()    — NSSetUncaughtExceptionHandler + signal handlers
DiagnosticLog.shared.log(...) calls from AppDelegate / CommandStore / ProcessManager / LiveAppController
PopoverView: "Show Log" → NSWorkspace.activateFileViewerSelecting(logURL)
```

## Components

### DiagnosticLog (`Diagnostics/DiagnosticLog.swift`)
- `init(fileURL:)` (injectable) + `static let shared = DiagnosticLog(fileURL: <default>)`.
- Private `serial DispatchQueue` serialises writes (calls come from different threads).
- `log(_ message: String, level: Level = .info)` → line `yyyy-MM-dd HH:mm:ss.SSS [LEVEL] message\n`, appended to the file (open append / FileHandle).
- **Rotation** on init: if the file exceeds 512 KB → rename to `<file>.1` (keep 1 backup), start fresh.
- Holds a pre-opened log fd for signal handlers.
- `Level: info / warn / error`.

### Crash capture (`DiagnosticLog.installCrashHandlers()`)
- `NSSetUncaughtExceptionHandler` → `log("UNCAUGHT EXCEPTION: \(name) \(reason)\n\(callStackSymbols)", .error)`.
- Signals SIGABRT/SIGSEGV/SIGILL/SIGTRAP/SIGBUS/SIGFPE: the handler writes `--- SIGNAL n ---` + `backtrace_symbols_fd(...)` to the pre-opened log fd (async-signal-safe, no malloc), restores the default handler, and calls `raise(sig)`. Best-effort (Swift `fatalError`/precondition are partially caught via SIGTRAP/SIGILL).

### Logging points (generous)
- **AppDelegate**: `applicationDidFinishLaunching` (launch, version, N commands), `applicationShouldTerminate` (N daemons, kill/leave/cancel choice), `installCrashHandlers()`.
- **CommandStore**: config loaded/reload (N commands), save, parse error, default config copy.
- **ProcessManager**: run command (name, sudo/daemon), termination (code/cancelled/stopped/idle), stop, chain (start/step/result), memory (quit/relaunch — which apps).
- **LiveAppController**: quit/relaunch result.

### UI (`PopoverView`)
- "Show Log" button in the footer → `NSWorkspace.shared.activateFileViewerSelecting([DiagnosticLog.shared.fileURL])`.

## Testing

- `DiagnosticLog` on a temporary file (TDD): lines are appended with timestamp+level; repeated
  calls accumulate; **rotation** when the limit is exceeded (`.1` file is created, the main file
  starts fresh).
- Logging points and the "Show Log" button — visual check (launch, open `devdeck.log`).
- Crash capture — best-effort, verified with an artificial crash manually (not in automated tests).

## Risks / Notes

- Signal handlers must be async-signal-safe: write only via `write()`/`backtrace_symbols_fd`
  to the open fd, no Foundation/malloc.
- Logging from `ProcessManager`/`CommandStore` in tests writes to the real `devdeck.log` (harmless);
  `DiagnosticLog` itself is tested on a separate temporary file.
- The log may contain command/application names — this is a local dev tool, no sensitive data.

## Out of Scope

- Sending logs anywhere, an in-app log viewer, structured (JSON) logging.
