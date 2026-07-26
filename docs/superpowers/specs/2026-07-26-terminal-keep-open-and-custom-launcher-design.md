# Design: Keep the Terminal Tab Alive + Custom Terminal Launcher

> Date: 2026-07-26. Status: designed, ready to implement.
> Touches the terminal launch path added pre-0.4.0 (`DevDeck/Process/TerminalCommandRunner.swift`).

## Problems

**1. The tab dies with the command.** A command run with "Open in terminal" ends with a footer and
`read`; pressing Enter ends the script, the shell exits and the terminal closes the tab. There is no
way to keep working in that shell — re-running the command by hand, poking at the directory it ran
in, or just reading the output at leisure all require opening a new terminal and `cd`-ing back.

**2. Only Ghostty is supported.** `/Applications/Ghostty.app` is hard-coded, and both launchers are
Ghostty-specific: one passes `-e`, the other talks to Ghostty's own AppleScript dictionary. Any other
terminal is simply unavailable.

## Decisions

| Question | Decision |
|---|---|
| What replaces "press Enter to close" | Drop into an interactive login shell (`exec`) in the same directory |
| Where that setting lives | Per-command — `Command.keepTerminalOpen` |
| How other terminals are supported | A user-configured command template, not a table of known apps |
| How the template relates to Ghostty | A **third** launch mode beside "window" and "tab"; Ghostty keeps working untouched |

## Part 1 — Keep the tab alive

`Command` gains `keepTerminalOpen: Bool` (memberwise default `false`, `decodeIfPresent ?? false`,
in `CodingKeys`). **No schema bump** — the key is optional and the decode is resilient key-by-key.

`GhosttyCommandRunner.script(_:pidFile:exitFile:)` ends differently depending on the flag:

```zsh
# today, and still the default
print -P "%F{8}[DevDeck] finished (code $code). Press Enter to close.%f"
read

# with keepTerminalOpen
print -P "%F{8}[DevDeck] finished (code $code). The shell stays open.%f"
exec "${SHELL:-/bin/zsh}" -l
```

`exec` replaces the script's shell in place, keeping the PID. That is safe for tracking because the
tracker has already emitted `.terminated` from the exit-code sentinel by then — DevDeck reports the
command's real exit code, and only afterwards does the tab become an ordinary shell. Its working
directory and exported environment are inherited, so a routed command leaves a shell that is still
pointed at the proxy (unless the user's own `.zshrc` overwrites those variables).

Everything else is unchanged: the stop button still kills the subtree while the command runs, and a
tab closed mid-run still produces `.terminated(143)` from PID death.

## The prerequisite: clean up run directories at launch, not mid-run

`GhosttyRunningProcess` deletes the whole temp directory the moment the exit-code sentinel appears,
and again when the startup timeout fires — in both cases possibly while zsh is still executing the
last lines of that same script.

That is **not** a corruption race, and the plan must not pretend otherwise. The interpreter holds an
open fd on the file; unlinking a path leaves the inode alive until the last descriptor closes, so
zsh keeps reading the rest of the script normally. (Verified: a 1.4 MB script whose directory was
deleted 0.4 s into a `sleep 1` ran every remaining line, `exec` included. Modifying a script in
place, unlike deleting it, genuinely does corrupt a running shell — but nothing here does that.)

The deletions still have to go, for two ordinary reasons:

- the startup-timeout deletion can simply be **wrong** — a terminal that took longer than 30 seconds
  to write its pid sentinel is still coming, and we would have removed the script it is about to run;
- a `run.zsh` left beside a live tab is worth having when something needs diagnosing, which is far
  more likely now that a tab can stay open indefinitely.

Fix:

- Drop the cleanup at the terminal event and at the startup timeout.
- Keep the cleanup on a launch failure: no terminal ever received that script, so it is of no use to
  anyone.
- Sweep on app start instead: delete leftover `devdeck-term-*` directories in the temp directory,
  but **only** those whose `pid` sentinel is missing (nothing ever started) or names a process that
  is no longer alive. A tab left running from a previous session therefore keeps its script until it
  finishes.

  The sweep lives in `TerminalCommandRunner.swift` as a free function with its liveness check
  injected, so the decision is testable against a temp directory without real processes:

  ```swift
  func sweepStaleTerminalDirectories(in baseDir: URL,
                                     isAlive: (Int32) -> Bool = { ProcessTree.isAlive($0) })
  ```

  `AppDelegate` calls it once at launch with the defaults. It only ever considers directories whose
  name starts with `devdeck-term-`; anything else in the temp directory is left alone.

## Part 2 — Custom terminal launcher

`TerminalLaunchMode` gains `case custom`. The template lives in `UserDefaults` under
`terminalLaunchCommand`, beside the existing `terminalLaunchMode` — the two are one setting in the
user's mind, and splitting terminal configuration across UserDefaults and `config.json` would make
neither authoritative. It is also machine-local by nature: it names binaries by path.

The template substitutes `{script}`:

```
/opt/homebrew/bin/wezterm start -- {script}
open -a iTerm {script}
kitty {script}
```

A new `CustomCommandLauncher: TerminalLauncher` sits beside `GhosttyLauncher` and
`AppleScriptTabLauncher`, and `ModeSelectingLauncher` gains it as a third branch — so the seam the
existing tests already exercise stays the only way a launch is chosen.

**Execution: `/bin/zsh -lc "<expanded template>"`.** Two reasons, both about not reinventing things:
the user gets the full shell syntax instead of whatever argv parser we would write, and `-l` picks up
their `PATH` from `.zshrc`, so `wezterm` resolves without an absolute path — exactly how every other
command in this app is launched. `{script}` is substituted through the existing `shQuote`, so a path
containing spaces cannot break the command apart.

**The process is not waited on.** A terminal that stays in the foreground (`alacritty -e` does)
would otherwise block the launcher's task before polling ever starts, and the command would sit in
`running` forever. Not waiting costs the ability to read a non-zero exit status from the spawn, but
that is already covered: when nothing writes the pid sentinel within `maxStartupTicks` (~30 s), the
runner reports `terminalDidNotStart`.

**Validation happens before launch, not after.** A pure
`expandTerminalLaunchCommand(template:scriptPath:) -> String?` returns nil for a blank template or
one with no `{script}` placeholder, and the launcher fails immediately with a dedicated message
rather than making the user wait out the 30-second timeout for an obvious typo.

The template **defaults to empty**, not to a guessed command line: a wrong default would launch
something the user never asked for, whereas an empty one selected by mistake fails instantly with a
message naming `{script}`. The examples live in the field's hint, where they can be copied.

## UI

Both settings go in the command editor, where the existing mode picker already lives (it is shown
under "Open in terminal"):

- the picker becomes **New window / Tab / Custom command**;
- a text field for the template appears only for **Custom command**, with a hint naming `{script}`;
- **"Stay in the shell after the command finishes"** sits next to "Open in terminal".

The mode and the template remain shared across commands (as the mode is today, labelled "shared");
`keepTerminalOpen` is per-command.

New `L10n` entries (EN + RU): `keepTerminalOpenToggle`, `keepTerminalOpenHint`, `terminalCustom`,
`terminalCustomCommandLabel`, `terminalCustomCommandHint`, `terminalCustomCommandInvalid`, and a
stays-open variant of `terminalDoneFooter`.

## Rejected

- **A table of per-app adapters** (iTerm2, WezTerm, kitty, Alacritty…). Each needs its own flags or
  AppleScript dictionary, the list is never finished, and every entry is a thing to keep working
  against someone else's release schedule. The template covers all of them and terminals that do not
  exist yet.
- **Replacing the Ghostty code with a template.** Would delete the tab mode: it runs through
  Ghostty's AppleScript and cannot be expressed as a command line. Ghostty users would lose a working
  feature to gain a setting they do not need.
- **A generic `open -a <App> {script}` path.** Works for Terminal.app and iTerm2 and silently does
  nothing useful for WezTerm, kitty or Alacritty — the failure mode is an app that opens and no
  command that runs, which reads as "DevDeck is broken". The template makes the mechanism explicit.
- **Parsing the template into argv ourselves.** A hand-rolled quote-aware splitter is a bug farm for
  no benefit over handing the string to a shell that already does it correctly.

## Testing

Extends the existing `DevDeckTests/TerminalRunnerTests.swift`, which already covers `script()` and
the mode selector with fakes:

- `script()` with `keepTerminalOpen` off — unchanged, still ends in `read` (regression guard);
- `script()` with it on — ends in `exec`, contains no `read`, and still writes the exit sentinel
  **before** the exec line, since the tracker depends on that ordering;
- `expandTerminalLaunchCommand` — substitution, a script path containing a space, a template with no
  `{script}` → nil, a blank template → nil;
- `ModeSelectingLauncher` routes to the custom launcher for `.custom` (it already asserts the two
  existing modes);
- the startup sweep: a directory with a dead pid is removed, one with a live pid is kept, one with no
  pid file is removed, and a foreign directory in the temp folder is untouched;
- `Command.keepTerminalOpen` round-trips and defaults to false.

Not unit-tested, by nature: that a given third-party terminal actually honours the user's template.
That is one manual check per terminal the user cares about.

## Files

**Change:** `Models/Command.swift` (+`keepTerminalOpen`); `Process/TerminalCommandRunner.swift`
(script ending, `.custom` mode, `CustomCommandLauncher`, `expandTerminalLaunchCommand`, cleanup
removal); `AppDelegate.swift` (startup sweep); `MainWindow/CommandEditorView.swift` (picker case,
template field, toggle); `Localization/L10n.swift`; `CHANGELOG.md`.

**Test:** `DevDeckTests/TerminalRunnerTests.swift`, `DevDeckTests/ConfigCodecTests.swift`.
