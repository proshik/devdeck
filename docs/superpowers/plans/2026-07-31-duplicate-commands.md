# Duplicate Commands Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Right-click any command, daemon or chain in the main window's sidebar and get a copy of it, named `X (copy)`, placed directly below the original and opened for editing.

**Architecture:** A pure naming helper (`DuplicateNaming`) decides the copy's name and is unit-tested in isolation. `CommandStore` grows two `duplicate` methods that build the copy, insert it after the original and persist. `MainWindowView` attaches a one-item `.contextMenu` to the sidebar rows and moves the selection onto the returned id.

**Tech Stack:** Swift 5, SwiftUI + AppKit, `@Observable`, XCTest. Xcode project `DevDeck.xcodeproj`, scheme `DevDeck`.

**Spec:** `docs/superpowers/specs/2026-07-31-duplicate-commands-design.md`

## Global Constraints

- **Test command** — `xcodebuild` needs an explicit developer dir on this machine, `xcode-select` points at CommandLineTools:
  ```
  DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
    -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'
  ```
  Add `-only-testing:DevDeckTests/<ClassName>` to run a single class.
- **No commits.** `CLAUDE.md` states "Do not commit without an explicit request from the user." Every task ends when its tests pass. Do not run `git commit`.
- **No `project.pbxproj` edits.** Both targets are `PBXFileSystemSynchronizedRootGroup`; new files under `DevDeck/` and `DevDeckTests/` are picked up automatically.
- **Copy marker words** — `copy` (English) and `копия` (Russian), verbatim. Both are always recognized when parsing an existing name, regardless of the active language.
- **Naming format** — `<root> (<marker>)` for the first copy, `<root> (<marker> N)` for N ≥ 2. No leading space when the root is empty.
- **Comment language** — English, matching every existing file in the project.

---

### Task 1: `DuplicateNaming` — the copy-name helper

**Files:**
- Create: `DevDeck/Store/DuplicateNaming.swift`
- Test: `DevDeckTests/DuplicateNamingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum DuplicateNaming` with
  `static func nextName(base: String, marker: String, knownMarkers: [String], existing: Set<String>) -> String`.
  Task 2 calls this.

- [ ] **Step 1: Write the failing tests**

Create `DevDeckTests/DuplicateNamingTests.swift`:

```swift
import XCTest
@testable import DevDeck

/// Naming of duplicated entries. Pure — no store, no files, no app language state,
/// so both locales are covered by passing the marker in.
final class DuplicateNamingTests: XCTestCase {

    private let markers = ["copy", "копия"]

    private func next(_ base: String, existing: Set<String>, marker: String = "copy") -> String {
        DuplicateNaming.nextName(base: base, marker: marker,
                                 knownMarkers: markers, existing: existing)
    }

    func testFirstCopyAppendsTheMarker() {
        XCTAssertEqual(next("deploy", existing: ["deploy"]), "deploy (copy)")
    }

    func testCollisionAdvancesToTwo() {
        XCTAssertEqual(next("deploy", existing: ["deploy", "deploy (copy)"]), "deploy (copy 2)")
    }

    func testDuplicatingACopyReusesTheRoot() {
        XCTAssertEqual(next("deploy (copy)", existing: ["deploy", "deploy (copy)"]),
                       "deploy (copy 2)",
                       "no 'deploy (copy) (copy)'")
    }

    func testNumberedCopyIsStrippedToo() {
        XCTAssertEqual(next("deploy (copy 2)",
                            existing: ["deploy", "deploy (copy)", "deploy (copy 2)"]),
                       "deploy (copy 3)")
    }

    func testGapInTheNumberingIsFilled() {
        XCTAssertEqual(next("deploy", existing: ["deploy", "deploy (copy)", "deploy (copy 3)"]),
                       "deploy (copy 2)",
                       "lowest free candidate, not highest used + 1")
    }

    func testEmptyNameGetsNoLeadingSpace() {
        XCTAssertEqual(next("", existing: []), "(copy)")
        XCTAssertEqual(next("", existing: ["(copy)"]), "(copy 2)")
    }

    func testMarkerFromTheOtherLanguageIsRecognized() {
        // A copy made in Russian, duplicated after the user switched to English.
        XCTAssertEqual(next("deploy (копия)", existing: ["deploy", "deploy (копия)"]),
                       "deploy (copy)")
    }

    func testRussianMarkerIsWrittenWhenAsked() {
        XCTAssertEqual(next("deploy", existing: ["deploy"], marker: "копия"), "deploy (копия)")
    }

    func testAMarkerInTheMiddleIsNotStripped() {
        XCTAssertEqual(next("deploy (copy) of prod", existing: []),
                       "deploy (copy) of prod (copy)",
                       "only a trailing marker is a copy suffix")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' \
  -only-testing:DevDeckTests/DuplicateNamingTests
```
Expected: compile error — `cannot find 'DuplicateNaming' in scope`.

- [ ] **Step 3: Write the implementation**

Create `DevDeck/Store/DuplicateNaming.swift`:

```swift
import Foundation

/// Builds the name for a duplicated command or chain: `deploy` → `deploy (copy)` → `deploy (copy 2)`.
///
/// Pure, and deliberately free of `L10n`: the marker word arrives as a parameter, so the tests can
/// cover both languages without touching the app-wide language setting.
enum DuplicateNaming {

    /// The lowest free copy name for `base`.
    ///
    /// `base` is the original's name, raw — a trailing copy marker is stripped here, so duplicating
    /// a copy yields `X (copy 2)` rather than `X (copy) (copy)`. Every marker in `knownMarkers` is
    /// recognized, not just the one being written: names live in `config.json` and outlive a
    /// language switch, and matching only the active marker would produce a duplicate name.
    static func nextName(base: String, marker: String,
                         knownMarkers: [String], existing: Set<String>) -> String {
        let root = strippingMarker(from: base, knownMarkers: knownMarkers)
        var index = 1
        while true {
            let candidate = name(root: root, marker: marker, index: index)
            if !existing.contains(candidate) { return candidate }
            index += 1
        }
    }

    private static func name(root: String, marker: String, index: Int) -> String {
        let suffix = index == 1 ? "(\(marker))" : "(\(marker) \(index))"
        return root.isEmpty ? suffix : "\(root) \(suffix)"
    }

    /// Drops a trailing `(copy)` / `(копия 3)`. Anchored at the end and preceded by whitespace or
    /// the start of the string — a marker in the middle of a name is part of that name.
    private static func strippingMarker(from name: String, knownMarkers: [String]) -> String {
        let alternatives = knownMarkers
            .map { NSRegularExpression.escapedPattern(for: $0) }
            .joined(separator: "|")
        guard !alternatives.isEmpty,
              let regex = try? NSRegularExpression(
                  pattern: "(?:^|\\s)\\((?:\(alternatives))(?: \\d+)?\\)$")
        else { return name }
        let range = NSRange(name.startIndex..., in: name)
        return regex.stringByReplacingMatches(in: name, range: range, withTemplate: "")
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run:
```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' \
  -only-testing:DevDeckTests/DuplicateNamingTests
```
Expected: PASS, 9 tests.

---

### Task 2: `L10n` strings and the two `CommandStore.duplicate` methods

**Files:**
- Modify: `DevDeck/Localization/L10n.swift` (append before the closing brace, after `copied`)
- Modify: `DevDeck/Store/CommandStore.swift` (after `delete(chainID:)`, around line 133)
- Test: `DevDeckTests/CommandStoreDuplicateTests.swift`

**Interfaces:**
- Consumes: `DuplicateNaming.nextName(base:marker:knownMarkers:existing:)` from Task 1.
- Produces:
  - `L10n.duplicate: String`, `L10n.copyMarker: String`, `L10n.copyMarkers: [String]`
  - `CommandStore.duplicate(commandID: UUID) -> UUID?`
  - `CommandStore.duplicate(chainID: UUID) -> UUID?`

  Both are `@discardableResult` and return the copy's id, `nil` when the original is absent. Task 3 calls all of these.

- [ ] **Step 1: Write the failing tests**

Create `DevDeckTests/CommandStoreDuplicateTests.swift`:

```swift
import XCTest
@testable import DevDeck

/// `CommandStore.duplicate` — fresh id, adjacent placement, verbatim fields, persistence.
///
/// The copy's exact name is not asserted: it carries `L10n.copyMarker`, which follows the app's
/// current language. `DuplicateNamingTests` pins the naming itself.
@MainActor
final class CommandStoreDuplicateTests: XCTestCase {

    private var dir: URL!
    private var url: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    func testCopyKeepsEveryFieldButIDAndName() throws {
        let store = CommandStore(configURL: url)
        let original = Command(id: UUID(), name: "forward", command: "kubectl port-forward",
                               workingDirectory: "/tmp", isDaemon: true, needsSudo: true,
                               env: ["A": "1"], appsToQuit: [], openInTerminal: true,
                               watchdogEnabled: true, port: 5432, routeThroughProxy: true,
                               promptForDirectory: true, keepTerminalOpen: true)
        store.upsert(original)

        let copyID = try XCTUnwrap(store.duplicate(commandID: original.id))
        let copy = try XCTUnwrap(store.commandsByID[copyID])

        XCTAssertNotEqual(copy.id, original.id, "fresh id")
        XCTAssertNotEqual(copy.name, original.name, "renamed")
        var expected = original
        expected.id = copy.id
        expected.name = copy.name
        XCTAssertEqual(copy, expected, "every other field copied verbatim, port included")
    }

    func testCopyLandsRightAfterTheOriginal() throws {
        let store = CommandStore(configURL: url)
        let first = Command(id: UUID(), name: "a", command: "echo a")
        let second = Command(id: UUID(), name: "b", command: "echo b")
        store.upsert(first)
        store.upsert(second)

        let copyID = try XCTUnwrap(store.duplicate(commandID: first.id))

        XCTAssertEqual(store.config.commands.map(\.id), [first.id, copyID, second.id])
    }

    func testDaemonCopyStaysADaemon() throws {
        let store = CommandStore(configURL: url)
        let daemon = Command(id: UUID(), name: "d", command: "sleep 1", isDaemon: true)
        store.upsert(daemon)

        let copyID = try XCTUnwrap(store.duplicate(commandID: daemon.id))

        XCTAssertTrue(try XCTUnwrap(store.commandsByID[copyID]).isDaemon,
                      "stays in the daemons section")
    }

    func testChainCopyIsShallowAndAdjacent() throws {
        let store = CommandStore(configURL: url)
        let member = UUID()
        let chain = Chain(id: UUID(), name: "c", commandIDs: [member], stopOnError: false)
        store.upsert(chain)

        let copyID = try XCTUnwrap(store.duplicate(chainID: chain.id))
        let copy = try XCTUnwrap(store.config.chains.first { $0.id == copyID })

        XCTAssertEqual(copy.commandIDs, [member], "members are referenced, not multiplied")
        XCTAssertFalse(copy.stopOnError, "other fields copied verbatim")
        XCTAssertEqual(store.config.chains.map(\.id), [chain.id, copyID])
    }

    func testDuplicatingAnUnknownIDIsANoOp() throws {
        let store = CommandStore(configURL: url)
        let command = Command(id: UUID(), name: "a", command: "echo")
        store.upsert(command)

        XCTAssertNil(store.duplicate(commandID: UUID()))
        XCTAssertNil(store.duplicate(chainID: UUID()))
        XCTAssertEqual(store.config.commands, [command], "nothing changed")
    }

    func testCopyIsPersisted() throws {
        let store = CommandStore(configURL: url)
        let command = Command(id: UUID(), name: "a", command: "echo")
        store.upsert(command)
        let copyID = try XCTUnwrap(store.duplicate(commandID: command.id))

        let fresh = CommandStore(configURL: url)
        fresh.reload()

        XCTAssertEqual(fresh.config.commands.map(\.id), [command.id, copyID],
                       "survived a round-trip through disk")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run:
```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' \
  -only-testing:DevDeckTests/CommandStoreDuplicateTests
```
Expected: compile error — no `duplicate` member on `CommandStore`.

- [ ] **Step 3: Add the localization entries**

In `DevDeck/Localization/L10n.swift`, immediately after `static var copied` and before the enum's closing brace:

```swift
    // MARK: - Duplicate

    static var duplicate: String { t("Duplicate", "Дублировать") }
    /// The word written into a duplicate's name: `deploy` → `deploy (copy)`.
    static var copyMarker: String { t("copy", "копия") }
    /// Every marker DevDeck can recognize inside an existing name — not just the active language's.
    /// Names live in config.json and outlive a language switch, so a copy made in Russian must
    /// still be recognized as a copy after switching to English.
    static let copyMarkers = ["copy", "копия"]
```

Note: `L10n.copy` already exists and means the clipboard verb ("Copy"/"Копировать"). Do not reuse or rename it.

- [ ] **Step 4: Add the store methods**

In `DevDeck/Store/CommandStore.swift`, after `delete(chainID:)` and before the `// MARK: proxy manager` section:

```swift
    /// Duplicate a command: a copy with a fresh id and the next free `(copy)` name, inserted
    /// directly after the original so it lands next to it in the sidebar section too (the sections
    /// are filters over this one array, and the copy keeps `isDaemon`).
    ///
    /// Returns the copy's id so the caller can select it. `nil` means the original is gone —
    /// an external edit to config.json between opening the context menu and clicking it.
    @discardableResult
    func duplicate(commandID: UUID) -> UUID? {
        guard let index = config.commands.firstIndex(where: { $0.id == commandID }) else { return nil }
        var copy = config.commands[index]
        copy.id = UUID()
        copy.name = DuplicateNaming.nextName(
            base: config.commands[index].name,
            marker: L10n.copyMarker,
            knownMarkers: L10n.copyMarkers,
            existing: Set(config.commands.map(\.name))
        )
        var updated = config
        updated.commands.insert(copy, at: index + 1)
        persist(updated)
        return copy.id
    }

    /// Duplicate a chain. Shallow: the copy references the same commands — `commandIDs` is carried
    /// over untouched, and no command is duplicated along with it.
    @discardableResult
    func duplicate(chainID: UUID) -> UUID? {
        guard let index = config.chains.firstIndex(where: { $0.id == chainID }) else { return nil }
        var copy = config.chains[index]
        copy.id = UUID()
        copy.name = DuplicateNaming.nextName(
            base: config.chains[index].name,
            marker: L10n.copyMarker,
            knownMarkers: L10n.copyMarkers,
            existing: Set(config.chains.map(\.name))
        )
        var updated = config
        updated.chains.insert(copy, at: index + 1)
        persist(updated)
        return copy.id
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run:
```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' \
  -only-testing:DevDeckTests/CommandStoreDuplicateTests
```
Expected: PASS, 6 tests.

---

### Task 3: The sidebar context menu

**Files:**
- Modify: `DevDeck/MainWindow/MainWindowView.swift` — `sidebarRow` (line 96-99), the chains `ForEach` (line 27-30), and two new private methods next to `addCommand` / `addChain` (line 120-131)

**Interfaces:**
- Consumes: `L10n.duplicate`, `CommandStore.duplicate(commandID:)`, `CommandStore.duplicate(chainID:)` from Task 2.
- Produces: nothing — this is the top of the stack.

There is no unit test here: this is a SwiftUI view with no logic beyond wiring, and the project has no view tests. It is verified by a clean build plus the manual check in Step 4.

- [ ] **Step 1: Attach the menu to command and daemon rows**

In `DevDeck/MainWindow/MainWindowView.swift`, replace `sidebarRow`:

```swift
    private func sidebarRow(_ command: Command, icon: String) -> some View {
        Label(command.name.isEmpty ? L10n.untitled : command.name, systemImage: icon)
            .tag(MainSelection.command(command.id))
            .contextMenu {
                Button(L10n.duplicate) { duplicateCommand(command.id) }
            }
    }
```

Both the Commands and the Daemons section route through this method, so one edit covers them.

- [ ] **Step 2: Attach the menu to chain rows**

In the same file, replace the body of the chains `ForEach`:

```swift
                Section(L10n.chains) {
                    ForEach(store.config.chains) { chain in
                        Label(chain.name.isEmpty ? L10n.untitled : chain.name, systemImage: "link")
                            .tag(MainSelection.chain(chain.id))
                            .contextMenu {
                                Button(L10n.duplicate) { duplicateChain(chain.id) }
                            }
                    }
                    .onMove { store.moveChains($0, to: $1) }
                }
```

- [ ] **Step 3: Add the two handlers**

In the same file, after `addChain()`:

```swift
    /// Selection follows the copy, which opens its editor — the same move `addCommand` makes,
    /// and the copy's name is the first thing worth changing. A `nil` id means the original was
    /// deleted from under us; leave the selection alone.
    private func duplicateCommand(_ id: UUID) {
        guard let copyID = store.duplicate(commandID: id) else { return }
        appModel.selection = .command(copyID)
    }

    private func duplicateChain(_ id: UUID) {
        guard let copyID = store.duplicate(chainID: id) else { return }
        appModel.selection = .chain(copyID)
    }
```

- [ ] **Step 4: Build, run the whole suite, and check it by hand**

Run:
```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'
```
Expected: build succeeds, the full suite passes with no regressions.

Then launch the app and confirm, in the main window:
1. Right-click a command → "Duplicate" appears → the copy shows up on the next row, named `… (copy)`, selected, with its editor open.
2. The same on a daemon → the copy stays in the Daemons section.
3. The same on a chain → the copy appears under the original and its step list matches.
4. Duplicate the same command twice → the second copy is `… (copy 2)`.
5. Quit and relaunch → the copies are still there (they went through `config.json`).

---

## Self-Review

**Spec coverage.** Naming helper → Task 1. `L10n` entries → Task 2 Step 3. Store methods, insertion after the original, `nil` on a missing original → Task 2 Step 4. Context menu on all three row kinds and the selection move → Task 3. Both test files → Tasks 1 and 2. The spec's "what the copy carries" is asserted by `testCopyKeepsEveryFieldButIDAndName`; "runtime state is not inherited" needs no code and no test — it follows from the fresh `UUID`, which `testCopyKeepsEveryFieldButIDAndName` already pins.

**Placeholders.** None — every step carries the code it needs.

**Type consistency.** `nextName(base:marker:knownMarkers:existing:)` is defined in Task 1 and called with those exact labels in Task 2. `duplicate(commandID:)` / `duplicate(chainID:)` return `UUID?` in Task 2 and are unwrapped with `guard let` in Task 3. `L10n.copyMarker` is a computed `String`, `L10n.copyMarkers` a stored `[String]` — matching the parameter types `marker: String` and `knownMarkers: [String]`.
