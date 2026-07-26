# Keep the Terminal Tab Alive + Custom Terminal Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a terminal command hand its tab over to an interactive shell instead of closing, and let any terminal — not just Ghostty — be used, via a user-supplied command template.

**Architecture:** Both features live in the existing terminal launch path. The tab-stays-open behaviour is a per-command flag that changes the tail of the generated wrapper script (`exec $SHELL` instead of `read`). Arbitrary terminals arrive as a third `TerminalLaunchMode` whose launcher runs the user's own command line through `zsh -lc` with `{script}` substituted. A prerequisite fix stops the runner deleting the wrapper script while zsh is still reading it.

**Tech Stack:** Swift 5, SwiftUI + AppKit, XCTest. No new dependencies.

## Global Constraints

- Design source of truth: `docs/superpowers/specs/2026-07-26-terminal-keep-open-and-custom-launcher-design.md`.
- **No config schema bump.** `keepTerminalOpen` is optional and decodes `decodeIfPresent ?? false`; `Config.currentSchemaVersion` stays **2**.
- Every user-facing string goes through `L10n` with EN and RU.
- New `.swift` files are picked up automatically (`PBXFileSystemSynchronizedRootGroup`) — **never edit `.pbxproj`**.
- No `Co-Authored-By` trailers in commit messages.
- Tests run with `DEVELOPER_DIR=/Applications/Xcode.app just test` (a bare `just test` fails — `xcode-select` points at CommandLineTools).
- Baseline before this work: **338 tests, 0 failures.**
- Default behaviour must not change for existing commands: `keepTerminalOpen` defaults false, launch mode still defaults to `.window`.
- The tracker's contract is unchanged: exactly one `.started`, then exactly one terminal event. The exit sentinel must still be written **before** anything that hands the tab over.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `DevDeck/Process/TerminalCommandRunner.swift` | sweep, script tail, `.custom` mode, `CustomCommandLauncher`, template expansion | Modify |
| `DevDeck/AppDelegate.swift` | call the sweep once at launch | Modify |
| `DevDeck/Models/Command.swift` | `keepTerminalOpen` | Modify |
| `DevDeck/MainWindow/CommandEditorView.swift` | picker case, template field, toggle | Modify |
| `DevDeck/Localization/L10n.swift` | new EN/RU strings | Modify |
| `DevDeckTests/TerminalRunnerTests.swift` | sweep, script tail, expansion, mode routing | Modify |
| `DevDeckTests/ConfigCodecTests.swift` | `keepTerminalOpen` round-trip | Modify |

---

### Task 1: Stop deleting the script under the interpreter

**Files:**
- Modify: `DevDeck/Process/TerminalCommandRunner.swift`, `DevDeck/AppDelegate.swift`
- Test: `DevDeckTests/TerminalRunnerTests.swift`

**Interfaces:**
- Consumes: `ProcessTree.isAlive(_:)` (existing).
- Produces: `sweepStaleTerminalDirectories(in:isAlive:)`.

This is the prerequisite for Task 2: today the runner deletes the whole run directory the moment the exit sentinel appears, while zsh is still executing the last lines of that same script. With `read` the race is usually won; with `exec` losing it closes the tab, which is exactly the feature being built.

- [ ] **Step 1: Write the failing tests**

Append to `DevDeckTests/TerminalRunnerTests.swift`, inside the existing class:

```swift
    // MARK: stale run-directory sweep

    /// Build a fake run directory; `pid` nil means the wrapper never started.
    private func makeRunDir(_ base: URL, _ name: String, pid: Int32?) throws -> URL {
        let dir = base.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let pid {
            try "\(pid)\n".write(to: dir.appendingPathComponent("pid"), atomically: true, encoding: .utf8)
        }
        return dir
    }

    func testSweepRemovesFinishedRunsAndKeepsLiveOnes() throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }

        let live = try makeRunDir(base, "devdeck-term-live", pid: 4242)
        let dead = try makeRunDir(base, "devdeck-term-dead", pid: 1)
        let never = try makeRunDir(base, "devdeck-term-never", pid: nil)
        let foreign = try makeRunDir(base, "someone-elses-dir", pid: nil)

        sweepStaleTerminalDirectories(in: base, isAlive: { $0 == 4242 })

        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: live.path),
                      "a tab still running from a previous session must keep its script")
        XCTAssertFalse(fm.fileExists(atPath: dead.path), "its terminal is gone — nothing can read it")
        XCTAssertFalse(fm.fileExists(atPath: never.path), "no pid sentinel means it never started")
        XCTAssertTrue(fm.fileExists(atPath: foreign.path),
                      "only our own devdeck-term-* directories are ours to delete")
    }

    func testSweepToleratesAnUnreadableBaseDirectory() {
        // Must not throw or trap when the temp directory can't be listed.
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-absent-\(UUID().uuidString)")
        sweepStaleTerminalDirectories(in: missing, isAlive: { _ in false })
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/TerminalRunnerTests 2>&1 | grep -E "error:|Executed"`

Expected: compile failure — `sweepStaleTerminalDirectories` not found.

- [ ] **Step 3: Add the sweep**

In `DevDeck/Process/TerminalCommandRunner.swift`, above `// MARK: - Terminal runner`:

```swift
/// Delete run directories left over by previous sessions.
///
/// The runner deliberately does NOT delete a directory when the command finishes: zsh reads the
/// wrapper script incrementally and is still executing its last lines at that moment, so removing it
/// underneath is a race — and losing it closes the tab, which is precisely what `keepTerminalOpen`
/// exists to prevent. Cleaning up at launch is safe instead, because a tab that is still running is
/// detectable: its `pid` sentinel names a live process.
///
/// `isAlive` is injected so the decision is testable without real processes.
func sweepStaleTerminalDirectories(
    in baseDir: URL = FileManager.default.temporaryDirectory,
    isAlive: (Int32) -> Bool = { ProcessTree.isAlive($0) }
) {
    let fm = FileManager.default
    guard let entries = try? fm.contentsOfDirectory(at: baseDir, includingPropertiesForKeys: nil)
    else { return }
    for dir in entries where dir.lastPathComponent.hasPrefix("devdeck-term-") {
        let pidText = try? String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8)
        let pid = pidText.flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        // A live pid means a tab from a previous session is still running this script.
        if let pid, isAlive(pid) { continue }
        try? fm.removeItem(at: dir)
    }
}
```

- [ ] **Step 4: Remove the two unsafe cleanups**

In `GhosttyRunningProcess.init`, delete the `try? FileManager.default.removeItem(at: dir)` line in **two** places — inside `if tracker.finished { … }` and inside the `startupTicks >= maxStartupTicks` branch. In both an interpreter may still hold the file.

**Keep** the one in the `catch` block after `launcher.launch` fails: the script was written but no terminal ever received it, so nothing can be reading it. Add a comment there saying exactly that, so it isn't "tidied" away later:

```swift
                // Safe to delete here and only here: the launch failed, so no interpreter ever
                // received this script. The other exits leave it to the startup sweep.
                try? FileManager.default.removeItem(at: dir)
```

- [ ] **Step 5: Call the sweep at launch**

In `DevDeck/AppDelegate.swift`, at the end of `applicationDidFinishLaunching`, after the `HotKeyManager.shared.setEnabled(...)` line:

```swift
        // Run directories are no longer deleted when a command finishes (zsh may still be reading
        // the script); collect the ones whose terminal is gone now instead.
        sweepStaleTerminalDirectories()
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app just test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with [0-9]+ failure|TEST (SUCCEEDED|FAILED)" | tail -4`

Expected: `TEST SUCCEEDED`, 340 tests (338 + 2).

- [ ] **Step 7: Commit**

```bash
git add DevDeck/Process/TerminalCommandRunner.swift DevDeck/AppDelegate.swift DevDeckTests/TerminalRunnerTests.swift
git commit -m "fix(terminal): sweep run directories at launch instead of deleting them mid-script"
```

---

### Task 2: Keep the tab alive after the command finishes

**Files:**
- Modify: `DevDeck/Models/Command.swift`, `DevDeck/Localization/L10n.swift`, `DevDeck/Process/TerminalCommandRunner.swift`
- Test: `DevDeckTests/TerminalRunnerTests.swift`, `DevDeckTests/ConfigCodecTests.swift`

**Interfaces:**
- Consumes: the sweep from Task 1 (the script must outlive the exit sentinel).
- Produces: `Command.keepTerminalOpen: Bool`, `L10n.terminalStaysOpenFooter(_:)`.

- [ ] **Step 1: Write the failing tests**

Append to `DevDeckTests/TerminalRunnerTests.swift`:

```swift
    func testScriptWaitsForEnterByDefault() {
        let command = Command(id: UUID(), name: "build", command: "just build", openInTerminal: true)
        let script = GhosttyCommandRunner.script(
            command,
            pidFile: URL(fileURLWithPath: "/tmp/p"), exitFile: URL(fileURLWithPath: "/tmp/e"))

        XCTAssertTrue(script.hasSuffix("read\n"), "unchanged default — the tab closes on Enter")
        XCTAssertFalse(script.contains("exec "))
    }

    func testScriptHandsTheTabToAShellWhenAsked() {
        let command = Command(id: UUID(), name: "claude", command: "claude",
                              openInTerminal: true, keepTerminalOpen: true)
        let script = GhosttyCommandRunner.script(
            command,
            pidFile: URL(fileURLWithPath: "/tmp/p"), exitFile: URL(fileURLWithPath: "/tmp/e"))

        XCTAssertTrue(script.contains("exec \"${SHELL:-/bin/zsh}\" -l"))
        XCTAssertFalse(script.contains("\nread\n"), "waiting for Enter would defeat the point")

        // The tracker reports the command's exit code from this sentinel. Writing it AFTER handing
        // the tab over would mean it never gets written at all.
        let exitWrite = try! XCTUnwrap(script.range(of: "> '/tmp/e'"))
        let exec = try! XCTUnwrap(script.range(of: "exec \""))
        XCTAssertTrue(exitWrite.upperBound < exec.lowerBound,
                      "the exit sentinel must be written before the exec")
    }
```

Append to `DevDeckTests/ConfigCodecTests.swift`, inside the existing class:

```swift
    func testKeepTerminalOpenRoundTripsAndDefaultsToFalse() throws {
        let command = Command(id: UUID(), name: "claude", command: "claude",
                              openInTerminal: true, keepTerminalOpen: true)
        let decoded = try ConfigCodec.decode(ConfigCodec.encode(Config(commands: [command])))
        XCTAssertEqual(decoded.commands.first?.keepTerminalOpen, true)

        let minimal = try ConfigCodec.decode(Data(#"{ "commands": [ { "name": "x", "command": "echo" } ] }"#.utf8))
        XCTAssertEqual(minimal.commands.first?.keepTerminalOpen, false)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/TerminalRunnerTests 2>&1 | grep -E "error:|Executed"`

Expected: compile failure — `Command` has no member `keepTerminalOpen`.

- [ ] **Step 3: Add the field**

In `DevDeck/Models/Command.swift`, after `var promptForDirectory: Bool`:

```swift
    /// When the command finishes in a terminal, hand the tab over to an interactive shell in the
    /// same directory instead of waiting for Enter and closing. For tools you re-run by hand, or
    /// when you want to poke around where the command ran.
    var keepTerminalOpen: Bool
```

Add `keepTerminalOpen: Bool = false` to the end of the memberwise init parameter list, and
`self.keepTerminalOpen = keepTerminalOpen` to the end of its body.

Extend `CodingKeys` — append `keepTerminalOpen` to the existing list.

Add to `init(from:)` after the `promptForDirectory` line:

```swift
        keepTerminalOpen = try c.decodeIfPresent(Bool.self, forKey: .keepTerminalOpen) ?? false
```

- [ ] **Step 4: Add the footer string**

In `DevDeck/Localization/L10n.swift`, next to `terminalDoneFooter`:

```swift
    /// Footer for a tab that stays open — the command is done, the shell is yours.
    static func terminalStaysOpenFooter(_ codeVar: String) -> String {
        t("[DevDeck] finished (code \(codeVar)). The shell is yours.",
          "[DevDeck] завершено (код \(codeVar)). Шелл в вашем распоряжении.")
    }
```

- [ ] **Step 5: Branch the script tail**

In `GhosttyCommandRunner.script(_:pidFile:exitFile:)`, replace the final three appended lines
(`echo`, the `print -P` footer, and `read`) with:

```swift
        lines.append("echo")
        if command.keepTerminalOpen {
            lines.append("print -P \"%F{8}\(L10n.terminalStaysOpenFooter("$code"))%f\"")
            // `exec` replaces this shell in place, so the tab becomes an ordinary login shell in the
            // same directory with the command's environment still exported. The exit sentinel is
            // written above, so DevDeck has already reported the real exit code by the time this runs.
            lines.append("exec \"${SHELL:-/bin/zsh}\" -l")
        } else {
            lines.append("print -P \"%F{8}\(L10n.terminalDoneFooter("$code"))%f\"")
            lines.append("read")
        }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app just test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with [0-9]+ failure|TEST (SUCCEEDED|FAILED)" | tail -4`

Expected: `TEST SUCCEEDED`, 343 tests (340 + 3).

- [ ] **Step 7: Commit**

```bash
git add DevDeck/Models/Command.swift DevDeck/Localization/L10n.swift \
        DevDeck/Process/TerminalCommandRunner.swift \
        DevDeckTests/TerminalRunnerTests.swift DevDeckTests/ConfigCodecTests.swift
git commit -m "feat(terminal): option to keep the tab as a shell after the command finishes"
```

---

### Task 3: Launch through the user's own command line

**Files:**
- Modify: `DevDeck/Process/TerminalCommandRunner.swift`, `DevDeck/Localization/L10n.swift`
- Test: `DevDeckTests/TerminalRunnerTests.swift`

**Interfaces:**
- Consumes: `GhosttyCommandRunner.shQuote(_:)`, `TerminalLauncherError`, `TerminalLauncher` (all existing).
- Produces: `TerminalLaunchMode.custom`, `TerminalLaunchMode.commandKey`, `expandTerminalLaunchCommand(template:scriptPath:)`, `CustomCommandLauncher`.

- [ ] **Step 1: Write the failing tests**

Append to `DevDeckTests/TerminalRunnerTests.swift`:

```swift
    // MARK: custom launch command

    func testExpandSubstitutesTheQuotedScriptPath() {
        let expanded = expandTerminalLaunchCommand(template: "wezterm start -- {script}",
                                                   scriptPath: "/tmp/run.zsh")
        XCTAssertEqual(expanded, "wezterm start -- '/tmp/run.zsh'")
    }

    func testExpandQuotesAPathWithSpaces() {
        // The path is ours (a temp dir), but the user's home may contain spaces.
        let expanded = expandTerminalLaunchCommand(template: "open -a iTerm {script}",
                                                   scriptPath: "/Users/a b/run.zsh")
        XCTAssertEqual(expanded, "open -a iTerm '/Users/a b/run.zsh'")
    }

    func testExpandRejectsATemplateWithoutThePlaceholder() {
        // The terminal would open with nothing to run, and the failure would look like a hang.
        XCTAssertNil(expandTerminalLaunchCommand(template: "wezterm start", scriptPath: "/tmp/r"))
    }

    func testExpandRejectsABlankTemplate() {
        XCTAssertNil(expandTerminalLaunchCommand(template: "", scriptPath: "/tmp/r"))
        XCTAssertNil(expandTerminalLaunchCommand(template: "   \n", scriptPath: "/tmp/r"))
    }

    func testModeSelectorRoutesToTheCustomLauncher() async throws {
        let win = RecordingLauncher()
        let tab = RecordingLauncher()
        let custom = RecordingLauncher()
        let url = URL(fileURLWithPath: "/tmp/run.zsh")

        try await ModeSelectingLauncher(window: win, tab: tab, custom: custom, mode: { .custom })
            .launch(scriptURL: url)

        XCTAssertEqual(custom.launched, [url])
        XCTAssertEqual(win.launched, [])
        XCTAssertEqual(tab.launched, [])
    }
```

`RecordingLauncher` already exists at file scope in this test file (a `final class … @unchecked Sendable` recording into `launched: [URL]`) — reuse it as-is. Because `custom:` gets a default value in Task 3 Step 5, the existing `testModeSelectorRoutesToWindowOrTab` keeps compiling unchanged; do not edit it.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/TerminalRunnerTests 2>&1 | grep -E "error:|Executed"`

Expected: compile failure — `expandTerminalLaunchCommand` not found, `ModeSelectingLauncher` has no `custom:` parameter.

- [ ] **Step 3: Add the mode, the key and the expansion**

In `DevDeck/Process/TerminalCommandRunner.swift`, replace the `TerminalLaunchMode` enum with:

```swift
/// Terminal launch mode (chosen in the UI, stored in UserDefaults).
enum TerminalLaunchMode: String {
    case window   // a new Ghostty window/instance (reliable, no permissions)
    case tab      // a new tab via Ghostty's native AppleScript (needs "Automation")
    case custom   // the user's own command line — any terminal, including ones we've never heard of
    static let key = "terminalLaunchMode"
    /// UserDefaults key for the `.custom` template. Beside `key` on purpose: the two are one
    /// setting in the user's mind, and splitting them across stores would make neither the source
    /// of truth.
    static let commandKey = "terminalLaunchCommand"
}

/// Substitute the wrapper script's path into the user's template. Pure.
///
/// nil when the template cannot work — blank, or missing the `{script}` placeholder. Rejecting it
/// here matters: a terminal launched with nothing to run looks exactly like DevDeck hanging, and the
/// user would wait out the 30-second startup timeout to learn about a typo.
func expandTerminalLaunchCommand(template: String, scriptPath: String) -> String? {
    let trimmed = template.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty, trimmed.contains("{script}") else { return nil }
    return trimmed.replacingOccurrences(of: "{script}",
                                        with: GhosttyCommandRunner.shQuote(scriptPath))
}
```

- [ ] **Step 4: Add the launcher**

In the same file, after `AppleScriptTabLauncher`:

```swift
/// Launches through the user's own command line — any terminal, including ones that don't exist yet.
///
/// Run via `zsh -lc` rather than a hand-rolled argv split: the user gets the full shell syntax, and
/// `-l` picks up their PATH from `.zshrc`, so `wezterm` resolves without an absolute path — exactly
/// how every other command in this app is launched.
///
/// Deliberately NOT waited on. A terminal that stays in the foreground (`alacritty -e` does) would
/// otherwise block the caller before polling ever starts, leaving the command stuck in `running`
/// forever. A template that fails inside zsh is caught by the runner's startup timeout instead.
struct CustomCommandLauncher: TerminalLauncher {
    let template: @Sendable () -> String

    init(template: @escaping @Sendable () -> String = {
        UserDefaults.standard.string(forKey: TerminalLaunchMode.commandKey) ?? ""
    }) {
        self.template = template
    }

    func launch(scriptURL: URL) async throws {
        guard let command = expandTerminalLaunchCommand(template: template(),
                                                        scriptPath: scriptURL.path) else {
            throw TerminalLauncherError(message: L10n.terminalCustomCommandInvalid)
        }
        DiagnosticLog.shared.log("Terminal: custom launch — \(command)")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", command]
        do {
            try process.run()   // not waited on — see the note above
        } catch {
            DiagnosticLog.shared.log("Terminal: custom launch failed — \(error.localizedDescription)",
                                     level: .error)
            throw TerminalLauncherError(message: L10n.terminalLaunchFailed(error.localizedDescription))
        }
    }
}
```

- [ ] **Step 5: Route the third mode**

In `ModeSelectingLauncher`, add the stored property, the init parameter (defaulting to
`CustomCommandLauncher()`) and the `switch` branch:

```swift
    let custom: any TerminalLauncher
```

```swift
        custom: any TerminalLauncher = CustomCommandLauncher(),
```

```swift
        self.custom = custom
```

```swift
        case .custom: try await custom.launch(scriptURL: scriptURL)
```

- [ ] **Step 6: Add the error string**

In `DevDeck/Localization/L10n.swift`, next to `terminalLaunchFailed`:

```swift
    static var terminalCustomCommandInvalid: String {
        t("The custom terminal command is empty or has no {script} placeholder — DevDeck wouldn’t know where to put the script.",
          "Своя команда терминала пуста или не содержит {script} — DevDeck негде подставить скрипт.")
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app just test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with [0-9]+ failure|TEST (SUCCEEDED|FAILED)" | tail -4`

Expected: `TEST SUCCEEDED`, 348 tests (343 + 5).

- [ ] **Step 8: Commit**

```bash
git add DevDeck/Process/TerminalCommandRunner.swift DevDeck/Localization/L10n.swift \
        DevDeckTests/TerminalRunnerTests.swift
git commit -m "feat(terminal): launch through a user-supplied command line for any terminal"
```

---

### Task 4: UI

**Files:**
- Modify: `DevDeck/Localization/L10n.swift`, `DevDeck/MainWindow/CommandEditorView.swift`, `CHANGELOG.md`

**Interfaces:**
- Consumes: `Command.keepTerminalOpen` (Task 2), `TerminalLaunchMode.custom` / `.commandKey` (Task 3).
- Produces: nothing consumed later.

- [ ] **Step 1: Add the L10n strings**

In `DevDeck/Localization/L10n.swift`, next to `terminalTab`:

```swift
    static var terminalCustom: String { t("Custom command", "Своя команда") }
    static var terminalCustomCommandLabel: String { t("Launch command", "Команда запуска") }
    static var terminalCustomCommandHint: String {
        t("{script} is replaced with the path to the generated script. Examples: wezterm start -- {script} · open -a iTerm {script} · kitty {script}",
          "{script} заменяется на путь к сгенерированному скрипту. Примеры: wezterm start -- {script} · open -a iTerm {script} · kitty {script}")
    }
    static var keepTerminalOpenToggle: String {
        t("Stay in the shell after the command finishes", "Оставаться в шелле после завершения команды")
    }
    static var keepTerminalOpenHint: String {
        t("The tab becomes an ordinary shell in the same directory instead of closing — for re-running the command by hand or looking around afterwards.",
          "Таб превращается в обычный шелл в той же папке вместо закрытия — чтобы перезапустить команду руками или осмотреться после неё.")
    }
```

- [ ] **Step 2: Extend the editor**

In `DevDeck/MainWindow/CommandEditorView.swift`, add next to the existing `@AppStorage` line:

```swift
    /// The `.custom` launch command — shared across commands, like the mode itself.
    @AppStorage("terminalLaunchCommand") private var terminalCommand = ""
```

Replace the `if draft.openInTerminal { … }` block with:

```swift
                if draft.openInTerminal {
                    Picker(L10n.terminalModePicker, selection: $terminalMode) {
                        Text(L10n.terminalWindow).tag(TerminalLaunchMode.window.rawValue)
                        Text(L10n.terminalTab).tag(TerminalLaunchMode.tab.rawValue)
                        Text(L10n.terminalCustom).tag(TerminalLaunchMode.custom.rawValue)
                    }
                    if terminalMode == TerminalLaunchMode.custom.rawValue {
                        TextField(L10n.terminalCustomCommandLabel, text: $terminalCommand)
                        Text(L10n.terminalCustomCommandHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Toggle(L10n.keepTerminalOpenToggle, isOn: $draft.keepTerminalOpen)
                    if draft.keepTerminalOpen {
                        Text(L10n.keepTerminalOpenHint)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
```

- [ ] **Step 3: Update the CHANGELOG**

In `CHANGELOG.md`, under `## [Unreleased]` → `### Added`:

```markdown
- **Terminal tabs can stay open.** A per-command "Stay in the shell after the command finishes"
  option hands the tab over to an ordinary shell in the same directory instead of closing it, so a
  command can be re-run by hand or its output read at leisure.
- **Any terminal, not just Ghostty.** A third launch mode, "Custom command", runs a command line you
  supply with `{script}` substituted — `wezterm start -- {script}`, `open -a iTerm {script}`, and so
  on. Ghostty keeps working with no configuration.
```

And under `### Fixed`:

```markdown
- Terminal run directories are no longer deleted while zsh is still reading the wrapper script; they
  are swept at the next launch instead, once their terminal is gone.
```

- [ ] **Step 4: Build and run the full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app just test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with [0-9]+ failure|TEST (SUCCEEDED|FAILED)" | tail -4`

Expected: `TEST SUCCEEDED`, 348 tests (Task 4 is view code, no new tests).

- [ ] **Step 5: Manual verification (the controller runs this with the user — do not attempt)**

Needs a real terminal: a command with "Stay in the shell" must leave a usable prompt in the same directory after finishing, and a `.custom` template must open the user's terminal and run the command.

- [ ] **Step 6: Commit**

```bash
git add DevDeck/Localization/L10n.swift DevDeck/MainWindow/CommandEditorView.swift CHANGELOG.md
git commit -m "feat(ui): terminal stay-open toggle and custom launch command"
```
