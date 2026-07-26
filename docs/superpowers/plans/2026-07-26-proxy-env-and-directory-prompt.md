# Terminal Helper + Per-Run Directory Prompt Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run any command through the active LAN proxy from any directory — from a terminal via a `dp` shell function, or from the deck via a one-shot directory prompt — without creating a DevDeck command per directory.

**Architecture:** DevDeck maintains `~/.config/devdeck/proxy.env` (URL + LAN prefix, mode 0600) from the same resolver that answers `routing(for:)`, so the terminal path and the in-app path can never disagree. A pasted zsh function reads those two keys, re-checks the LAN itself, and prefixes the command's environment. Separately, a `promptForDirectory` flag makes the popover ask for a directory and run a non-persisted copy of the command bound to it.

**Tech Stack:** Swift 5, SwiftUI + AppKit, `@Observable`, XCTest. No new dependencies.

## Global Constraints

- Design source of truth: `docs/superpowers/specs/2026-07-26-proxy-env-and-directory-prompt-design.md`.
- **No config schema bump.** `promptForDirectory` is optional; decode stays resilient key-by-key (`decodeIfPresent ?? default`). `Config.currentSchemaVersion` stays **2**.
- Every user-facing **app** string goes through `L10n` with EN and RU. The shell snippet is the one deliberate exception — it is code the user pastes into `.zshrc`, kept English-only.
- New `.swift` files are picked up automatically (`PBXFileSystemSynchronizedRootGroup`) — **never edit `.pbxproj`**.
- No `Co-Authored-By` trailers in commit messages.
- Tests run with `DEVELOPER_DIR=/Applications/Xcode.app just test` (a bare `just test` fails — `xcode-select` points at CommandLineTools).
- Baseline before this work: **305 tests, 0 failures.**
- `ProxyManager.store` is a `weak var`; a test that drops the store binding deallocates it mid-test and fails an unrelated assertion. Keep it in a bound local (see `makeManagerKeepingStore`).
- Tests must never touch the real `~/.config` — file IO goes through the injected `ProxyEnvFileWriting`.
- The protective invariant stands: no usable proxy means a flagged command **fails**, never a direct connection. A missing `proxy.env` is likewise the safe state — the helper refuses.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `DevDeck/Models/Command.swift` | `promptForDirectory`, `withWorkingDirectory(_:)` | Modify |
| `DevDeck/Proxy/ProxyRouting.swift` | extract `proxyURL(host:port:user:pass:)` | Modify |
| `DevDeck/Proxy/ProxyEnvFile.swift` | file contents builder + `ProxyEnvFileWriting` + `LiveProxyEnvFile` | Create |
| `DevDeck/Proxy/ProxyShellHelper.swift` | the zsh snippet text + the displayed path | Create |
| `DevDeck/Proxy/ProxyManager.swift` | `resolvedEndpoint()`, env-file refresh, new dependency | Modify |
| `DevDeck/MenuBar/PopoverView.swift` | `NSOpenPanel` on run | Modify |
| `DevDeck/MainWindow/CommandEditorView.swift` | toggle + hint | Modify |
| `DevDeck/MainWindow/ProxyShareEditorView.swift` | snippet block + Copy button | Modify |
| `DevDeck/Localization/L10n.swift` | new EN/RU strings | Modify |
| `DevDeckTests/Support/FakeProxyEnvFile.swift` | records contents / remove count | Create |

---

### Task 1: Per-run working directory on the model

**Files:**
- Modify: `DevDeck/Models/Command.swift`
- Test: `DevDeckTests/CommandWorkingDirectoryTests.swift` (create), `DevDeckTests/ConfigCodecTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `Command.promptForDirectory: Bool` and `Command.withWorkingDirectory(_ path: String?) -> Command`.

- [ ] **Step 1: Write the failing tests**

Create `DevDeckTests/CommandWorkingDirectoryTests.swift`:

```swift
import XCTest
@testable import DevDeck

/// `withWorkingDirectory` — the pure half of the per-run directory prompt. The panel itself is
/// AppKit and lives in the view; this is what actually decides what gets launched.
final class CommandWorkingDirectoryTests: XCTestCase {

    private func sample() -> Command {
        Command(id: UUID(), name: "claude", command: "claude", workingDirectory: "/original",
                env: ["A": "b"], openInTerminal: true, routeThroughProxy: true,
                promptForDirectory: true)
    }

    func testBindsTheChosenDirectory() {
        let bound = sample().withWorkingDirectory("/Users/x/project")

        XCTAssertEqual(bound.workingDirectory, "/Users/x/project")
    }

    func testEveryOtherFieldSurvives() {
        let original = sample()
        let bound = original.withWorkingDirectory("/tmp")

        XCTAssertEqual(bound.id, original.id, "same id — supervision state and logs must not split")
        XCTAssertEqual(bound.name, original.name)
        XCTAssertEqual(bound.command, original.command)
        XCTAssertEqual(bound.env, original.env)
        XCTAssertTrue(bound.openInTerminal)
        XCTAssertTrue(bound.routeThroughProxy, "the proxy flag must survive — that's the whole point")
        XCTAssertTrue(bound.promptForDirectory)
    }

    func testNilOrEmptyLeavesTheCommandAlone() {
        let original = sample()

        XCTAssertEqual(original.withWorkingDirectory(nil), original, "callers don't have to branch")
        XCTAssertEqual(original.withWorkingDirectory(""), original)
    }

    func testTheReceiverIsNotMutated() {
        let original = sample()
        _ = original.withWorkingDirectory("/tmp")

        XCTAssertEqual(original.workingDirectory, "/original", "the stored command keeps its own value")
    }
}
```

Append to `DevDeckTests/ConfigCodecTests.swift`, inside the existing class:

```swift
    func testPromptForDirectoryRoundTripsAndDefaultsToFalse() throws {
        let command = Command(id: UUID(), name: "claude", command: "claude", promptForDirectory: true)
        let decoded = try ConfigCodec.decode(ConfigCodec.encode(Config(commands: [command])))
        XCTAssertEqual(decoded.commands.first?.promptForDirectory, true)

        let minimal = try ConfigCodec.decode(Data(#"{ "commands": [ { "name": "x", "command": "echo" } ] }"#.utf8))
        XCTAssertEqual(minimal.commands.first?.promptForDirectory, false)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/CommandWorkingDirectoryTests 2>&1 | grep -E "error:|Executed"`

Expected: compile failure — `Command` has no member `promptForDirectory`.

- [ ] **Step 3: Add the field and the method**

In `DevDeck/Models/Command.swift`, after `var routeThroughProxy: Bool`:

```swift
    /// Ask for a working directory each time this command is launched from the deck, instead of
    /// storing one. Lets a single "claude" command serve every project. Direct runs only —
    /// a chain step has no UI to ask from and uses its own `workingDirectory`.
    var promptForDirectory: Bool
```

Add to the memberwise init parameter list, after `routeThroughProxy: Bool = false`:

```swift
        promptForDirectory: Bool = false
```

and to its body, after `self.routeThroughProxy = routeThroughProxy`:

```swift
        self.promptForDirectory = promptForDirectory
```

Extend `CodingKeys` — replace `watchdogEnabled, port, routeThroughProxy` with:

```swift
             watchdogEnabled, port, routeThroughProxy, promptForDirectory
```

Add to `init(from:)` after the `routeThroughProxy` line:

```swift
        promptForDirectory = try c.decodeIfPresent(Bool.self, forKey: .promptForDirectory) ?? false
```

Add the method inside `struct Command`, after `init(from:)`:

```swift
    /// A copy bound to a directory chosen at launch time. `nil`/empty returns an unchanged copy so
    /// the caller doesn't branch. Never persisted — the stored command keeps its own value.
    func withWorkingDirectory(_ path: String?) -> Command {
        guard let path, !path.isEmpty else { return self }
        var copy = self
        copy.workingDirectory = path
        return copy
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app just test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with [0-9]+ failure|TEST (SUCCEEDED|FAILED)" | tail -4`

Expected: `TEST SUCCEEDED`, 310 tests (305 + 5).

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Models/Command.swift DevDeckTests/CommandWorkingDirectoryTests.swift DevDeckTests/ConfigCodecTests.swift
git commit -m "feat(model): per-run working directory for a command"
```

---

### Task 2: The proxy.env file layer

**Files:**
- Modify: `DevDeck/Proxy/ProxyRouting.swift`
- Create: `DevDeck/Proxy/ProxyEnvFile.swift`, `DevDeckTests/Support/FakeProxyEnvFile.swift`, `DevDeckTests/ProxyEnvFileTests.swift`

**Interfaces:**
- Consumes: `urlEscapeProxyCredential` (existing, `ProxyRouting.swift`).
- Produces: `proxyURL(host:port:user:pass:) -> String`, `proxyEnvFileContents(url:lanPrefix:) -> String`, `protocol ProxyEnvFileWriting { func write(_:); func remove() }`, `LiveProxyEnvFile`, `FakeProxyEnvFile`.

- [ ] **Step 1: Write the failing tests**

Create `DevDeckTests/ProxyEnvFileTests.swift`:

```swift
import XCTest
@testable import DevDeck

/// The file the terminal helper reads. Pure text — the writer itself is exercised through
/// `FakeProxyEnvFile` in the manager's tests, so nothing here touches the real ~/.config.
final class ProxyEnvFileTests: XCTestCase {

    func testContentsCarryTheTwoKeysTheHelperReads() {
        let text = proxyEnvFileContents(url: "http://192.168.31.117:9999", lanPrefix: "192.168.31")

        XCTAssertTrue(text.contains("DEVDECK_PROXY_URL=http://192.168.31.117:9999"))
        XCTAssertTrue(text.contains("DEVDECK_PROXY_LAN=192.168.31"))
    }

    func testContentsAreNotShellExecutable() {
        // The helper reads keys instead of sourcing the file, so a tampered file can't run code.
        // Emitting `export` lines would invite someone to "simplify" the helper into `source`.
        let text = proxyEnvFileContents(url: "http://h:1", lanPrefix: "10.0.0")

        XCTAssertFalse(text.contains("export "))
        XCTAssertTrue(text.hasPrefix("#"), "leads with the do-not-edit header")
        XCTAssertTrue(text.hasSuffix("\n"), "trailing newline so `sed` sees the last line")
    }

    func testURLIsBuiltByTheSameHelperAsTheInjectedEnv() {
        // One builder for both paths — otherwise escaping could drift between them.
        let url = proxyURL(host: "h", port: 1, user: "u@corp", pass: "p:a@ss/word")

        XCTAssertEqual(url, "http://u%40corp:p%3Aa%40ss%2Fword@h:1")
        XCTAssertEqual(proxyEnv(host: "h", port: 1, user: "u@corp", pass: "p:a@ss/word")["HTTPS_PROXY"], url)
    }

    func testURLWithoutCredentials() {
        XCTAssertEqual(proxyURL(host: "192.168.31.117", port: 9999, user: nil, pass: nil),
                       "http://192.168.31.117:9999")
        XCTAssertEqual(proxyURL(host: "h", port: 1, user: "", pass: "p"), "http://h:1",
                       "an empty user must not produce a ':p@' prefix")
    }
}
```

Create `DevDeckTests/Support/FakeProxyEnvFile.swift`:

```swift
import Foundation
@testable import DevDeck

/// Records what would have been written to `~/.config/devdeck/proxy.env` — the real path is never
/// touched by tests.
final class FakeProxyEnvFile: ProxyEnvFileWriting, @unchecked Sendable {
    private let lock = NSLock()
    private var _contents: String?
    private var _removeCount = 0
    private var _writeCount = 0

    /// Last written contents; nil when the file has been removed (or never written).
    var contents: String? { lock.lock(); defer { lock.unlock() }; return _contents }
    var removeCount: Int { lock.lock(); defer { lock.unlock() }; return _removeCount }
    var writeCount: Int { lock.lock(); defer { lock.unlock() }; return _writeCount }

    func write(_ contents: String) {
        lock.lock(); defer { lock.unlock() }
        _contents = contents
        _writeCount += 1
    }

    func remove() {
        lock.lock(); defer { lock.unlock() }
        _contents = nil
        _removeCount += 1
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/ProxyEnvFileTests 2>&1 | grep -E "error:|Executed"`

Expected: compile failure — `proxyEnvFileContents`/`proxyURL` not found.

- [ ] **Step 3: Extract `proxyURL`**

In `DevDeck/Proxy/ProxyRouting.swift`, replace the body of `proxyEnv(host:port:user:pass:)` and add the extracted builder above it:

```swift
/// The proxy URL. Extracted so the injected environment and the terminal helper's `proxy.env` are
/// built from ONE place — escaping drifting between them would be invisible until it broke.
func proxyURL(host: String, port: Int, user: String?, pass: String?) -> String {
    let auth = user.flatMap { $0.isEmpty ? nil : $0 }
        .map { "\(urlEscapeProxyCredential($0)):\(urlEscapeProxyCredential(pass ?? ""))@" } ?? ""
    return "http://\(auth)\(host):\(port)"
}

/// Build the proxy environment injected into a routed command.
///
/// Both cases are emitted: `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY` and their lowercase twins —
/// curl and many Go/Node CLIs read only one of the two, and which one is not predictable.
/// `gost -L auto://` speaks HTTP CONNECT on the same port, so an `http://` URL covers HTTPS too.
func proxyEnv(host: String, port: Int, user: String?, pass: String?) -> [String: String] {
    let url = proxyURL(host: host, port: port, user: user, pass: pass)
    return [
        "HTTPS_PROXY": url, "HTTP_PROXY": url, "ALL_PROXY": url,
        "https_proxy": url, "http_proxy": url, "all_proxy": url,
        "NO_PROXY": proxyNoProxyList, "no_proxy": proxyNoProxyList,
    ]
}
```

- [ ] **Step 4: Create the file layer**

Create `DevDeck/Proxy/ProxyEnvFile.swift`:

```swift
import Foundation

/// Contents of `~/.config/devdeck/proxy.env` — the handshake between DevDeck and the `dp` shell
/// helper. Pure.
///
/// Plain `KEY=value`, deliberately NOT `export` lines: the helper reads the two keys it wants
/// rather than `source`-ing the file, so a corrupted or tampered file cannot execute anything.
func proxyEnvFileContents(url: String, lanPrefix: String) -> String {
    """
    # Written by DevDeck — do not edit, regenerated when the active proxy changes.
    DEVDECK_PROXY_URL=\(url)
    DEVDECK_PROXY_LAN=\(lanPrefix)

    """
}

/// Maintains the file the terminal helper reads. Behind a protocol (probe pattern, like everything
/// else in this directory) so tests never touch the real `~/.config`.
protocol ProxyEnvFileWriting: Sendable {
    func write(_ contents: String)
    func remove()
}

/// The real file at `~/.config/devdeck/proxy.env`, owner-readable only.
struct LiveProxyEnvFile: ProxyEnvFileWriting {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/devdeck/proxy.env")

    init() {}

    func write(_ contents: String) {
        let url = Self.url
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            DiagnosticLog.shared.log("Proxy env file: could not create the directory — "
                + error.localizedDescription, level: .warn)
            return
        }
        // createFile (not an atomic write-then-rename) so the mode is set AT creation: this file can
        // carry the proxy password, and an atomic write would briefly leave it world-readable.
        // It's small and rewritten whole, and a torn read only makes the helper refuse — the safe way.
        let ok = FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8),
                                                attributes: [.posixPermissions: 0o600])
        if !ok {
            DiagnosticLog.shared.log("Proxy env file: write failed at \(url.path)", level: .warn)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.url)
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app just test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with [0-9]+ failure|TEST (SUCCEEDED|FAILED)" | tail -4`

Expected: `TEST SUCCEEDED`, 314 tests (310 + 4).

- [ ] **Step 6: Commit**

```bash
git add DevDeck/Proxy/ProxyRouting.swift DevDeck/Proxy/ProxyEnvFile.swift \
        DevDeckTests/Support/FakeProxyEnvFile.swift DevDeckTests/ProxyEnvFileTests.swift
git commit -m "feat(proxy): proxy.env file layer for the terminal helper"
```

---

### Task 3: Keep proxy.env in step with the in-app verdict

**Files:**
- Modify: `DevDeck/Proxy/ProxyManager.swift`
- Test: `DevDeckTests/ProxyManagerEnvFileTests.swift` (create)

**Interfaces:**
- Consumes: `ProxyEnvFileWriting`, `proxyEnvFileContents`, `proxyURL` (Task 2); `lanPrefix(of:)`, `lanIP` (existing).
- Produces: `ProxyManager.init(… envFile: any ProxyEnvFileWriting = LiveProxyEnvFile())`.

- [ ] **Step 1: Write the failing tests**

Create `DevDeckTests/ProxyManagerEnvFileTests.swift`:

```swift
import XCTest
@testable import DevDeck

/// `~/.config/devdeck/proxy.env` must track the same verdict `routing(for:)` gives, or the terminal
/// helper and the app would disagree about whether a proxy is usable.
@MainActor
final class ProxyManagerEnvFileTests: XCTestCase {

    private var dir: URL!
    private var url: URL!
    private var retainedStore: CommandStore?

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("config.json")
    }

    override func tearDownWithError() throws {
        retainedStore = nil
        try? FileManager.default.removeItem(at: dir)
    }

    /// The store is retained for the test's lifetime — `ProxyManager.store` is weak.
    private func makeRig(lanIP: String? = "192.168.31.84",
                         credentials: FakeProxyCredentialStore = FakeProxyCredentialStore())
    -> (ProxyManager, CommandStore, FakeProxyDiscovering, FakeProxyEnvFile) {
        let store = CommandStore(configURL: url)
        store.setProxyDiscoveryEnabled(true)
        let discovering = FakeProxyDiscovering()
        let envFile = FakeProxyEnvFile()
        let manager = ProxyManager(discovering: discovering,
                                   advertiser: FakeProxyAdvertising(),
                                   credentials: credentials,
                                   lanIP: { lanIP },
                                   envFile: envFile)
        manager.store = store
        retainedStore = store
        return (manager, store, discovering, envFile)
    }

    private func proxy(_ name: String, host: String = "192.168.31.117", port: Int = 9999,
                       auth: Bool = false) -> DiscoveredProxy {
        DiscoveredProxy(name: name, host: host, port: port, authRequired: auth,
                        exitIP: nil, proto: "http+socks", schema: 1)
    }

    func testWritesTheFileWhenAProxyResolves() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }

        manager.setActiveProxy(proxy("personal-mac"))

        let contents = try! XCTUnwrap(envFile.contents)
        XCTAssertTrue(contents.contains("DEVDECK_PROXY_URL=http://192.168.31.117:9999"))
        XCTAssertTrue(contents.contains("DEVDECK_PROXY_LAN=192.168.31"),
                      "the prefix comes from this machine's own LAN address")
    }

    func testRepeatedBrowseUpdatesDoNotRewriteTheFile() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))
        let writesAfterSelection = envFile.writeCount

        // Bonjour re-emits the same set constantly; an unguarded write would hit the disk each time.
        for _ in 0..<5 {
            fake.emit([proxy("personal-mac")])
            await Task.yield()
        }

        XCTAssertEqual(envFile.writeCount, writesAfterSelection,
                       "an unchanged endpoint must not rewrite the file")
    }

    func testAChangedEndpointDoesRewriteTheFile() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))

        fake.emit([proxy("personal-mac", host: "192.168.31.200")])
        await yieldUntil { manager.activeProxy?.host == "192.168.31.200" }

        XCTAssertTrue(try! XCTUnwrap(envFile.contents).contains("http://192.168.31.200:9999"),
                      "the guard must not suppress a real change")
    }

    func testRemovesTheFileWhenNoProxyResolves() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))
        XCTAssertNotNil(envFile.contents)

        manager.setActiveProxy(nil)

        XCTAssertNil(envFile.contents, "a missing file is the safe state — the helper refuses")
        XCTAssertGreaterThan(envFile.removeCount, 0)
    }

    func testStoppingDiscoveryRemovesTheFile() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))
        XCTAssertNotNil(envFile.contents)

        manager.setDiscoveryEnabled(false)

        XCTAssertNil(envFile.contents, "discovery off must stop the terminal path too, not just the app")
    }

    func testNoLANAddressRemovesTheFile() async {
        let (manager, _, fake, envFile) = makeRig(lanIP: nil)
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }

        manager.setActiveProxy(proxy("personal-mac"))

        XCTAssertNil(envFile.contents, "without a LAN prefix the helper could not verify the network")
    }

    func testCredentialsAreIncludedWhenTheProxyRequiresThem() async {
        let credentials = FakeProxyCredentialStore([ProxyCredentialAccount.client("locked"): "s3cret"])
        let (manager, _, fake, envFile) = makeRig(credentials: credentials)
        manager.startDiscovery()
        fake.emit([proxy("locked", auth: true)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("locked", auth: true))

        // Deliberate trade-off, documented in the design: a terminal helper cannot read the Keychain,
        // so an authenticated proxy puts the password in this 0600 file or is unusable from a shell.
        manager.setClientCredentials(username: "dev", password: "s3cret", for: "locked")

        XCTAssertTrue(try! XCTUnwrap(envFile.contents).contains("http://dev:s3cret@192.168.31.117:9999"))
    }

    func testAuthProxyWithoutCredentialsRemovesTheFile() async {
        let (manager, _, fake, envFile) = makeRig()
        manager.startDiscovery()
        fake.emit([proxy("locked", auth: true)])
        await yieldUntil { manager.discovered.count == 1 }

        manager.setActiveProxy(proxy("locked", auth: true))

        XCTAssertNil(envFile.contents, "same verdict as routing(for:) — unusable means no file")
        XCTAssertEqual(manager.routing(for: Command(id: UUID(), name: "c", command: "c",
                                                    routeThroughProxy: true)), .unavailable)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/ProxyManagerEnvFileTests 2>&1 | grep -E "error:|Executed"`

Expected: compile failure — `ProxyManager.init` has no `envFile` parameter.

- [ ] **Step 3: Add the dependency**

In `DevDeck/Proxy/ProxyManager.swift`, add a stored property next to the other injected ones (after `exitIPRetryDelay`):

```swift
    /// Maintains `~/.config/devdeck/proxy.env` for the `dp` shell helper.
    @ObservationIgnored private let envFile: any ProxyEnvFileWriting
    /// Last contents handed to `envFile`, so a browse update that changes nothing doesn't rewrite
    /// the file. nil means the file is absent as far as we know.
    @ObservationIgnored private var lastProxyEnvContents: String?
```

Add the init parameter after `exitIPRetryDelay: Duration = .seconds(1)`:

```swift
        envFile: any ProxyEnvFileWriting = LiveProxyEnvFile()
```

and assign it in the body after `self.exitIPRetryDelay = exitIPRetryDelay`:

```swift
        self.envFile = envFile
```

- [ ] **Step 4: Extract the shared resolver and refresh the file**

Replace `routing(for:)` with the version below and add the two private helpers next to `refreshCredentialCache()`:

```swift
    /// Resolve how a command should be launched. Wired into `ProcessManager.proxyRouting` by
    /// `AppDelegate`, so `ProcessManager` never learns this type exists.
    func routing(for command: Command) -> ProxyRouting {
        guard command.routeThroughProxy else { return .notRouted }
        guard let resolved = resolvedEndpoint() else { return .unavailable }
        // This whole feature exists because the original failure was invisible — so say it out loud
        // when a run leans on the cache. Logged HERE and not in `activeProxy`, which SwiftUI reads
        // on every render; `routing(for:)` runs once per launch.
        if !resolved.proxy.isLive {
            DiagnosticLog.shared.log(
                "Proxy routing “\(command.name)” through the remembered address of “\(resolved.proxy.name)” "
                    + "(\(resolved.proxy.host):\(resolved.proxy.port)) — it is not announced on the LAN right now")
        }
        return .routed(env: proxyEnv(host: resolved.proxy.host, port: resolved.proxy.port,
                                     user: resolved.user, pass: resolved.pass))
    }
```

```swift
    /// The active proxy resolved to something usable, or nil when a flagged command must fail.
    /// Shared by `routing(for:)` and the terminal helper's env file, so the two can never disagree
    /// about whether a proxy is usable.
    private func resolvedEndpoint() -> (proxy: DiscoveredProxy, user: String?, pass: String?)? {
        guard let proxy = activeProxy else { return nil }
        guard proxy.authRequired else { return (proxy, nil, nil) }
        guard let username = store?.config.settings.activeProxyUsername, !username.isEmpty,
              let password = clientPassword(for: proxy.name), !password.isEmpty else { return nil }
        return (proxy, username, password)
    }

    /// Keep `proxy.env` in step with the in-app verdict. Removing it is the safe state: without the
    /// file the `dp` helper refuses to run, which mirrors `.unavailable` failing a flagged command.
    ///
    /// Guarded against redundant writes: this runs on every Bonjour browse update, and an
    /// unconditional write would hit the disk several times a second on a live network.
    private func refreshProxyEnvFile() {
        guard let resolved = resolvedEndpoint(),
              let ip = lanIP(), let prefix = lanPrefix(of: ip) else {
            if lastProxyEnvContents != nil {
                lastProxyEnvContents = nil
                envFile.remove()
            }
            return
        }
        let url = proxyURL(host: resolved.proxy.host, port: resolved.proxy.port,
                           user: resolved.user, pass: resolved.pass)
        let contents = proxyEnvFileContents(url: url, lanPrefix: prefix)
        guard contents != lastProxyEnvContents else { return }
        lastProxyEnvContents = contents
        envFile.write(contents)
    }

    /// Everything derived from the active choice, refreshed together so the two can't drift.
    private func refreshDerivedState() {
        refreshCredentialCache()
        refreshProxyEnvFile()
    }
```

Then replace every existing **call** to `refreshCredentialCache()` with `refreshDerivedState()` — there are four (in `start()`, in the `startDiscovery` loop, and the `defer` in `setActiveProxy` and in `setClientCredentials`). Leave the `private func refreshCredentialCache()` definition itself unchanged.

Finally add a refresh to `stopDiscovery()`, after `discovered = []`:

```swift
        refreshDerivedState()   // discovery off must stop the terminal path too
```

Note for the reviewer: routing the log through `resolvedEndpoint()` also fixes a wrinkle noted in the previous review — the "remembered address" line used to be logged before the credential check, so an auth proxy with no stored password logged "routing…" and then returned `.unavailable`. It now only logs when the run actually proceeds.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app just test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with [0-9]+ failure|TEST (SUCCEEDED|FAILED)" | tail -4`

Expected: `TEST SUCCEEDED`, 322 tests (314 + 8).

- [ ] **Step 6: Commit**

```bash
git add DevDeck/Proxy/ProxyManager.swift DevDeckTests/ProxyManagerEnvFileTests.swift
git commit -m "feat(proxy): keep proxy.env in step with the routing verdict"
```

---

### Task 4: The shell helper

**Files:**
- Create: `DevDeck/Proxy/ProxyShellHelper.swift`, `DevDeckTests/ProxyShellHelperTests.swift`

**Interfaces:**
- Consumes: nothing (the snippet is self-contained text).
- Produces: `proxyShellHelperSnippet: String`, `proxyEnvFileDisplayPath: String`.

- [ ] **Step 1: Write the failing tests**

Create `DevDeckTests/ProxyShellHelperTests.swift`:

```swift
import XCTest
@testable import DevDeck

/// The `dp` helper actually run under zsh. Only the REFUSAL paths are asserted: they are the
/// security-relevant branches and they are deterministic. The success path depends on the machine's
/// live network — asserting it here would just re-implement the interface scan and prove nothing;
/// it is verified by hand (`dp curl -s https://api.ipify.org`).
final class ProxyShellHelperTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".config/devdeck"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeEnvFile(_ contents: String) throws {
        try contents.write(to: home.appendingPathComponent(".config/devdeck/proxy.env"),
                           atomically: true, encoding: .utf8)
    }

    /// Runs the snippet under zsh with a sandboxed HOME, then `dp /bin/echo MARKER`.
    private func runHelper() throws -> (status: Int32, output: String) {
        let script = proxyShellHelperSnippet + "\ndp /bin/echo MARKER\n"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func testRefusesWhenTheEnvFileIsMissing() throws {
        let result = try runHelper()

        XCTAssertNotEqual(result.status, 0, "no active proxy must not silently run the command direct")
        XCTAssertFalse(result.output.contains("MARKER"), "the wrapped command must not have run")
    }

    func testRefusesOnADifferentNetwork() throws {
        // TEST-NET-3 (RFC 5737) — cannot match any real interface on this machine.
        try writeEnvFile("""
        DEVDECK_PROXY_URL=http://203.0.113.9:9999
        DEVDECK_PROXY_LAN=203.0.113

        """)

        let result = try runHelper()

        XCTAssertNotEqual(result.status, 0, "a remembered address must not be dialled off its own LAN")
        XCTAssertFalse(result.output.contains("MARKER"))
    }

    func testRefusesWhenTheEnvFileIsIncomplete() throws {
        try writeEnvFile("DEVDECK_PROXY_URL=http://192.168.31.117:9999\n")

        let result = try runHelper()

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.output.contains("MARKER"))
    }

    func testSnippetDoesNotSourceTheEnvFile() {
        // Sourcing would turn a data file into a code-execution surface.
        XCTAssertFalse(proxyShellHelperSnippet.contains("source "))
        XCTAssertFalse(proxyShellHelperSnippet.contains(". $f"))
    }

    func testSnippetScansInterfacesInsteadOfTheDefaultRoute() {
        // Under a full-tunnel corporate VPN the default route is a utun*, whose address
        // `ipconfig getifaddr` does not report — deriving the interface from it would break the
        // check in exactly the situation this helper exists for.
        XCTAssertFalse(proxyShellHelperSnippet.contains("route -n get default"))
        XCTAssertTrue(proxyShellHelperSnippet.contains("ifconfig -l"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/ProxyShellHelperTests 2>&1 | grep -E "error:|Executed"`

Expected: compile failure — `proxyShellHelperSnippet` not found.

- [ ] **Step 3: Create the snippet**

Create `DevDeck/Proxy/ProxyShellHelper.swift`:

```swift
import Foundation

/// Path shown in the UI next to the snippet, so the connection between the two is visible.
let proxyEnvFileDisplayPath = "~/.config/devdeck/proxy.env"

/// The zsh function the user pastes into `.zshrc`: run anything through the active LAN proxy from
/// whatever directory the shell is already in.
///
/// **English-only on purpose.** This is code the user pastes into their shell, not app UI, so it
/// does not go through `L10n` — only the section title, hint and button around it do.
///
/// Two things here are load-bearing and must not be "simplified":
/// - It READS two keys rather than `source`-ing the file: a data file must not be able to run code.
/// - It finds the LAN address by scanning `en*`, NOT from `route -n get default`. Under a
///   full-tunnel corporate VPN the default route points at a `utun*`, whose address
///   `ipconfig getifaddr` does not report — the network check would then fail in exactly the
///   situation this helper exists to serve. Scanning `en*` mirrors `pickLANIPv4`.
///
/// The env assignments are a command prefix, so they apply to that process only and never leak
/// into the calling shell — the same containment the in-app injection gives.
let proxyShellHelperSnippet = """
dp() {
  local f=$HOME/.config/devdeck/proxy.env url lan ip iface
  [[ -r $f ]] || { print -u2 "dp: DevDeck has no active proxy"; return 1; }
  url=$(sed -n 's/^DEVDECK_PROXY_URL=//p' $f)
  lan=$(sed -n 's/^DEVDECK_PROXY_LAN=//p' $f)
  [[ -n $url && -n $lan ]] || { print -u2 "dp: proxy.env is incomplete"; return 1; }
  for iface in ${(f)"$(ifconfig -l | tr ' ' '\\n')"}; do
    [[ $iface == en* ]] && ip=$(ipconfig getifaddr $iface 2>/dev/null) && [[ -n $ip ]] && break
  done
  [[ -n $ip && ${ip%.*} == $lan ]] || { print -u2 "dp: proxy $lan is not on this network"; return 1; }
  HTTPS_PROXY=$url HTTP_PROXY=$url ALL_PROXY=$url \\
  https_proxy=$url http_proxy=$url all_proxy=$url \\
  NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 "$@"
}
"""
```

Note the doubled backslashes: inside a Swift multi-line string `\\n` produces the literal `\n` zsh needs for `tr`, and `\\` at end of line produces the shell's line continuation.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app just test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with [0-9]+ failure|TEST (SUCCEEDED|FAILED)" | tail -4`

Expected: `TEST SUCCEEDED`, 327 tests (322 + 5).

If a zsh test fails, print the captured output — the helper's own message on stderr says which branch refused.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Proxy/ProxyShellHelper.swift DevDeckTests/ProxyShellHelperTests.swift
git commit -m "feat(proxy): dp shell helper for running commands through the LAN proxy"
```

---

### Task 5: UI

**Files:**
- Modify: `DevDeck/Localization/L10n.swift`, `DevDeck/MenuBar/PopoverView.swift`, `DevDeck/MainWindow/CommandEditorView.swift`, `DevDeck/MainWindow/ProxyShareEditorView.swift`, `CHANGELOG.md`

**Interfaces:**
- Consumes: `Command.promptForDirectory`, `Command.withWorkingDirectory(_:)` (Task 1); `proxyShellHelperSnippet`, `proxyEnvFileDisplayPath` (Task 4).
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the L10n strings**

In `DevDeck/Localization/L10n.swift`, in the `// MARK: - Proxy manager` section:

```swift
    static var promptForDirectoryToggle: String {
        t("Ask for a directory on every run", "Спрашивать директорию при каждом запуске")
    }
    static var promptForDirectoryHint: String {
        t("One command for every project: the directory is chosen at launch and is not saved. Applies to runs from the deck — a chain step uses its own working directory.",
          "Одна команда на все проекты: директория выбирается при запуске и не сохраняется. Работает при запуске из деки — шаг цепочки использует свою рабочую директорию.")
    }
    static var chooseRunDirectory: String { t("Run here", "Запустить здесь") }
    static var proxyTerminalHelperSection: String { t("Terminal helper", "Помощник для терминала") }
    static var proxyTerminalHelperHint: String {
        t("Paste this into ~/.zshrc, then run anything through the active proxy from any directory: dp claude. It reads the file below and refuses if that proxy is not on the current network.",
          "Вставьте это в ~/.zshrc, и запускайте что угодно через активный прокси из любой директории: dp claude. Функция читает файл ниже и откажется работать, если этот прокси не в текущей сети.")
    }
    static var copy: String { t("Copy", "Копировать") }
    static var copied: String { t("Copied", "Скопировано") }
```

- [ ] **Step 2: Prompt for the directory in the popover**

In `DevDeck/MenuBar/PopoverView.swift`, replace `toggleCommand(_:)` and add the panel helper next to it:

```swift
    private func toggleCommand(_ command: Command) {
        if StatusIndicator.forCommand(manager.states[command.id]).isStop {
            manager.stop(command.id)
        } else if command.promptForDirectory {
            runAfterChoosingDirectory(command)
        } else {
            manager.run(command)
        }
    }

    /// Ask where to run, then launch a copy bound to that directory — the stored command is
    /// untouched, so one "claude" serves every project.
    ///
    /// `NSApp.activate()` first: the popover is `.transient` and dismisses as soon as the panel
    /// takes focus, and without activating, the panel can open behind other windows.
    private func runAfterChoosingDirectory(_ command: Command) {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.chooseRunDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }
        manager.run(command.withWorkingDirectory(url.path))
    }
```

- [ ] **Step 3: Add the toggle to the command editor**

In `DevDeck/MainWindow/CommandEditorView.swift`, immediately after the `Toggle(L10n.openInTerminalToggle, isOn: $draft.openInTerminal)` line and its `if draft.openInTerminal { … }` block:

```swift
                Toggle(L10n.promptForDirectoryToggle, isOn: $draft.promptForDirectory)
                if draft.promptForDirectory {
                    Text(L10n.promptForDirectoryHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
```

- [ ] **Step 4: Show the snippet on the Proxy page**

In `DevDeck/MainWindow/ProxyShareEditorView.swift`, add `@State private var didCopy = false` next to the other `@State` properties, add `terminalHelperSection` to the `Form` body after `discoverySection`, and add the section itself:

```swift
    @ViewBuilder
    private var terminalHelperSection: some View {
        Section(L10n.proxyTerminalHelperSection) {
            Text(L10n.proxyTerminalHelperHint).font(.caption).foregroundStyle(.secondary)
            Text(proxyShellHelperSnippet)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack {
                Text(proxyEnvFileDisplayPath)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(didCopy ? L10n.copied : L10n.copy) { copySnippet() }
            }
        }
    }

    private func copySnippet() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(proxyShellHelperSnippet, forType: .string)
        didCopy = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            didCopy = false
        }
    }
```

`ProxyShareEditorView.swift` imports only SwiftUI today; add `import AppKit` at the top for `NSPasteboard`.

- [ ] **Step 5: Update the CHANGELOG**

In `CHANGELOG.md`, under `## [Unreleased]` → `### Added`, add a bullet after the Proxy Manager entry:

```markdown
- **Run through the proxy from anywhere**: a `dp` shell function (copy it from the Proxy page into
  `~/.zshrc`) routes any command through the active proxy from whatever directory you're in —
  `dp claude`. It reads `~/.config/devdeck/proxy.env`, which DevDeck keeps in step with the app's
  own routing verdict, and refuses to run when that proxy is not on the current network. For runs
  from the deck, a new "Ask for a directory on every run" flag lets one command serve every
  project — the directory is chosen at launch and never saved.
```

- [ ] **Step 6: Build and run the full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app just test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with [0-9]+ failure|TEST (SUCCEEDED|FAILED)" | tail -4`

Expected: `TEST SUCCEEDED`, 327 tests (Task 5 is view code, no new tests).

- [ ] **Step 7: Manual verification (controller runs this with the user — do not attempt)**

Requires the two-Mac setup and a live proxy: paste the snippet into `.zshrc`, then in a fresh shell `dp curl -s https://api.ipify.org` must print the VPN egress IP; and a command with "Ask for a directory on every run" must open the panel and launch in the chosen directory.

- [ ] **Step 8: Commit**

```bash
git add DevDeck/Localization/L10n.swift DevDeck/MenuBar/PopoverView.swift \
        DevDeck/MainWindow/CommandEditorView.swift DevDeck/MainWindow/ProxyShareEditorView.swift \
        CHANGELOG.md
git commit -m "feat(ui): terminal helper snippet and per-run directory prompt"
```
