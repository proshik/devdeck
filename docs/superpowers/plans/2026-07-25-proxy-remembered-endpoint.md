# Remembered Proxy Endpoint Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Keep a `routeThroughProxy` command working while the active proxy is reachable but no longer discoverable, by remembering its last known `host:port`.

**Architecture:** Three optional fields on `Settings` hold the endpoint of the *current* active proxy. `ProxyManager` writes them at exactly two points (a fresh browse result containing the active peer, and explicit selection) and reads them as a fallback in `activeProxy`, synthesizing a `DiscoveredProxy` marked `isLive: false`. The UI keeps listing the active proxy even when it is only remembered.

**Tech Stack:** Swift 5, SwiftUI + AppKit, `@Observable`, XCTest. No new dependencies.

## Global Constraints

- Design source of truth: `docs/superpowers/specs/2026-07-25-proxy-remembered-endpoint-design.md`.
- **No config schema bump.** New keys are optional; decode stays resilient key-by-key (`decodeIfPresent ?? default`).
- Every user-facing string goes through `L10n` with EN and RU variants.
- New `.swift` files are picked up automatically (`PBXFileSystemSynchronizedRootGroup`) — **never edit `.pbxproj`**.
- Never commit without an explicit request from the user (`CLAUDE.md`).
- No `Co-Authored-By` trailers in commit messages.
- Tests run with `DEVELOPER_DIR=/Applications/Xcode.app just test` (plain `just test` fails: `xcode-select` points at CommandLineTools).
- Baseline before this work: **283 tests, 0 failures.**
- The protective invariant must survive: with neither a live nor a remembered endpoint, a flagged command **fails**; it never falls back to a direct connection.

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `DevDeck/Models/Config.swift` | `Settings` gains 3 endpoint fields | Modify |
| `DevDeck/Store/CommandStore.swift` | `rememberActiveProxyEndpoint`, clearing on deselect | Modify |
| `DevDeck/Proxy/ProxyDiscovery.swift` | `DiscoveredProxy.isLive` | Modify |
| `DevDeck/Proxy/ProxyManager.swift` | cache read (`activeProxy`), cache write, `visibleProxies` | Modify |
| `DevDeck/MenuBar/ProxySectionView.swift` | list remembered proxy, dimmed + caption | Modify |
| `DevDeck/MainWindow/ProxyShareEditorView.swift` | same in the Proxy page | Modify |
| `DevDeck/Localization/L10n.swift` | one new EN/RU string | Modify |
| `DevDeckTests/ProxyConfigCodecTests.swift` | persistence of the new fields | Modify |
| `DevDeckTests/ProxyManagerDiscoveryTests.swift` | fallback, precedence, write-on-change | Modify |
| `DevDeckTests/ProxyManagerRoutingResolutionTests.swift` | routing from a remembered endpoint | Modify |

---

### Task 1: Persist the endpoint

**Files:**
- Modify: `DevDeck/Models/Config.swift` (`Settings`)
- Modify: `DevDeck/Store/CommandStore.swift` (`setActiveProxy`, new mutator)
- Test: `DevDeckTests/ProxyConfigCodecTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `Settings.activeProxyHost: String?`, `Settings.activeProxyPort: Int?`, `Settings.activeProxyAuthRequired: Bool`, and `CommandStore.rememberActiveProxyEndpoint(host: String, port: Int, authRequired: Bool)`. `CommandStore.setActiveProxy(name:username:)` keeps its signature and additionally clears all three fields when `name` is nil.

- [ ] **Step 1: Write the failing tests**

Append to `DevDeckTests/ProxyConfigCodecTests.swift`, inside the existing `final class ProxyConfigCodecTests: XCTestCase`:

```swift
    func testRememberedEndpointRoundTrips() throws {
        var config = Config.empty
        config.settings.activeProxyName = "personal-mac"
        config.settings.activeProxyHost = "192.168.31.117"
        config.settings.activeProxyPort = 9999
        config.settings.activeProxyAuthRequired = true

        let decoded = try ConfigCodec.decode(ConfigCodec.encode(config))

        XCTAssertEqual(decoded.settings.activeProxyHost, "192.168.31.117")
        XCTAssertEqual(decoded.settings.activeProxyPort, 9999)
        XCTAssertEqual(decoded.settings.activeProxyAuthRequired, true)
    }

    func testFileWithoutRememberedEndpointDecodesToDefaults() throws {
        // A config written by 0.5.0 has the active proxy but no cached endpoint.
        let older = Data(#"{"commands":[],"settings":{"activeProxyName":"personal-mac"}}"#.utf8)

        let config = try ConfigCodec.decode(older)

        XCTAssertEqual(config.settings.activeProxyName, "personal-mac")
        XCTAssertNil(config.settings.activeProxyHost)
        XCTAssertNil(config.settings.activeProxyPort)
        XCTAssertFalse(config.settings.activeProxyAuthRequired)
        XCTAssertEqual(config.schemaVersion, 2, "adding optional keys does not bump the schema")
    }
```

Create `DevDeckTests/CommandStoreProxyEndpointTests.swift`:

```swift
import XCTest
@testable import DevDeck

/// Persistence of the active proxy's last known endpoint — the fallback used when Bonjour goes
/// quiet (a corporate VPN blocks multicast while leaving unicast TCP working).
@MainActor
final class CommandStoreProxyEndpointTests: XCTestCase {

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

    func testRememberEndpointPersists() throws {
        let store = CommandStore(configURL: url)
        store.setActiveProxy(name: "personal-mac")

        store.rememberActiveProxyEndpoint(host: "192.168.31.117", port: 9999, authRequired: false)

        XCTAssertEqual(store.config.settings.activeProxyHost, "192.168.31.117")
        XCTAssertEqual(store.config.settings.activeProxyPort, 9999)

        let fresh = CommandStore(configURL: url)
        fresh.reload()
        XCTAssertEqual(fresh.config.settings.activeProxyHost, "192.168.31.117",
                       "survives a restart — that is the whole point")
    }

    func testRepeatedIdenticalRememberDoesNotRewriteTheFile() throws {
        let store = CommandStore(configURL: url)
        store.rememberActiveProxyEndpoint(host: "192.168.31.117", port: 9999, authRequired: false)
        let firstWrite = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        // Every Bonjour browse update calls this; an unguarded write would hit the disk constantly.
        for _ in 0..<5 {
            store.rememberActiveProxyEndpoint(host: "192.168.31.117", port: 9999, authRequired: false)
        }
        let lastWrite = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        XCTAssertEqual(firstWrite, lastWrite, "an unchanged endpoint must not touch the file")
    }

    func testChangedEndpointIsPersisted() {
        let store = CommandStore(configURL: url)
        store.rememberActiveProxyEndpoint(host: "192.168.31.117", port: 9999, authRequired: false)

        store.rememberActiveProxyEndpoint(host: "192.168.31.200", port: 8888, authRequired: true)

        XCTAssertEqual(store.config.settings.activeProxyHost, "192.168.31.200")
        XCTAssertEqual(store.config.settings.activeProxyPort, 8888)
        XCTAssertTrue(store.config.settings.activeProxyAuthRequired)
    }

    func testDeselectingTheProxyClearsTheEndpoint() {
        let store = CommandStore(configURL: url)
        store.setActiveProxy(name: "personal-mac", username: "dev")
        store.rememberActiveProxyEndpoint(host: "192.168.31.117", port: 9999, authRequired: true)

        store.setActiveProxy(name: nil, username: nil)

        XCTAssertNil(store.config.settings.activeProxyName)
        XCTAssertNil(store.config.settings.activeProxyHost, "a stale endpoint must not outlive the choice")
        XCTAssertNil(store.config.settings.activeProxyPort)
        XCTAssertFalse(store.config.settings.activeProxyAuthRequired)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/CommandStoreProxyEndpointTests 2>&1 | grep -E "error:|Executed"`

Expected: compile failure — `value of type 'Settings' has no member 'activeProxyHost'`.

- [ ] **Step 3: Add the fields to `Settings`**

In `DevDeck/Models/Config.swift`, after `var activeProxyUsername: String?`:

```swift
    /// Last known address of the active proxy. Bonjour dies on networks that filter multicast
    /// (any corporate VPN), while the proxy itself stays reachable over unicast TCP — this is
    /// what keeps a flagged command working there. One endpoint for the CURRENT choice, not a
    /// per-peer table.
    var activeProxyHost: String?
    var activeProxyPort: Int?
    /// Cached alongside the address: without it a remembered auth-protected proxy would resolve
    /// as open and skip the credentials requirement.
    var activeProxyAuthRequired: Bool
```

Extend the memberwise `init` parameter list (after `activeProxyUsername: String? = nil`):

```swift
         activeProxyHost: String? = nil, activeProxyPort: Int? = nil,
         activeProxyAuthRequired: Bool = false) {
```

and its body (after `self.activeProxyUsername = activeProxyUsername`):

```swift
        self.activeProxyHost = activeProxyHost
        self.activeProxyPort = activeProxyPort
        self.activeProxyAuthRequired = activeProxyAuthRequired
```

Extend `CodingKeys` — replace the `activeProxyName, activeProxyUsername` line with:

```swift
             activeProxyName, activeProxyUsername, activeProxyHost, activeProxyPort,
             activeProxyAuthRequired
```

Extend `init(from:)` after the `activeProxyUsername` line:

```swift
        activeProxyHost = try c.decodeIfPresent(String.self, forKey: .activeProxyHost)
        activeProxyPort = try c.decodeIfPresent(Int.self, forKey: .activeProxyPort)
        activeProxyAuthRequired = try c.decodeIfPresent(Bool.self, forKey: .activeProxyAuthRequired) ?? false
```

- [ ] **Step 4: Add the store mutators**

In `DevDeck/Store/CommandStore.swift`, replace the body of `setActiveProxy(name:username:)` with:

```swift
    func setActiveProxy(name: String?, username: String? = nil) {
        guard config.settings.activeProxyName != name
                || config.settings.activeProxyUsername != username else { return }
        var updated = config
        updated.settings.activeProxyName = name
        updated.settings.activeProxyUsername = username
        if name == nil {
            // The endpoint belongs to the choice — keeping it would let a stale address
            // resurrect a proxy the user deselected.
            updated.settings.activeProxyHost = nil
            updated.settings.activeProxyPort = nil
            updated.settings.activeProxyAuthRequired = false
        }
        persist(updated)
    }

    /// Remember where the active proxy was last reachable, so it survives Bonjour going quiet.
    /// Guarded: this is called on every browse update, and an unguarded write would hit the disk
    /// several times a second.
    func rememberActiveProxyEndpoint(host: String, port: Int, authRequired: Bool) {
        guard config.settings.activeProxyHost != host
                || config.settings.activeProxyPort != port
                || config.settings.activeProxyAuthRequired != authRequired else { return }
        var updated = config
        updated.settings.activeProxyHost = host
        updated.settings.activeProxyPort = port
        updated.settings.activeProxyAuthRequired = authRequired
        persist(updated)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app just test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with [0-9]+ failure|TEST (SUCCEEDED|FAILED)" | tail -4`

Expected: `TEST SUCCEEDED`, 289 tests (283 baseline + 6 new).

- [ ] **Step 6: Commit** (only if the user has asked for commits; otherwise skip and report)

```bash
git add DevDeck/Models/Config.swift DevDeck/Store/CommandStore.swift \
        DevDeckTests/ProxyConfigCodecTests.swift DevDeckTests/CommandStoreProxyEndpointTests.swift
git commit -m "feat(model): persist the active proxy's last known endpoint"
```

---

### Task 2: Fall back to the remembered endpoint

**Files:**
- Modify: `DevDeck/Proxy/ProxyDiscovery.swift` (`DiscoveredProxy`)
- Modify: `DevDeck/Proxy/ProxyManager.swift` (`activeProxy`, `startDiscovery`, `setActiveProxy`, `visibleProxies`)
- Test: `DevDeckTests/ProxyManagerDiscoveryTests.swift`, `DevDeckTests/ProxyManagerRoutingResolutionTests.swift`

**Interfaces:**
- Consumes: `Settings.activeProxyHost/Port/AuthRequired` and `CommandStore.rememberActiveProxyEndpoint(host:port:authRequired:)` from Task 1.
- Produces: `DiscoveredProxy.isLive: Bool` (defaults to `true`), and `ProxyManager.visibleProxies: [DiscoveredProxy]` for Task 3.

- [ ] **Step 1: Write the failing tests**

Append to `DevDeckTests/ProxyManagerDiscoveryTests.swift` inside the existing class:

```swift
    func testRemembersTheEndpointOfTheActiveProxy() async {
        let (manager, store, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }

        manager.setActiveProxy(proxy("personal-mac"))

        XCTAssertEqual(store.config.settings.activeProxyHost, "192.168.1.42")
        XCTAssertEqual(store.config.settings.activeProxyPort, 9999)
    }

    func testFallsBackToTheRememberedEndpointWhenBonjourGoesQuiet() async {
        // The work Mac's corporate VPN filters multicast: the announcement disappears while the
        // proxy stays reachable over unicast TCP. Verified live on 2026-07-25.
        let (manager, _, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))

        fake.emit([])
        await yieldUntil { manager.discovered.isEmpty }

        let active = try! XCTUnwrap(manager.activeProxy)
        XCTAssertEqual(active.host, "192.168.1.42")
        XCTAssertEqual(active.port, 9999)
        XCTAssertFalse(active.isLive, "marked as remembered so the UI can say so")
    }

    func testLiveAnnouncementWinsOverTheRememberedEndpoint() async {
        let (manager, _, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac", host: "192.168.1.42")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac", host: "192.168.1.42"))

        // The peer comes back on a new address — live data must override the cached one.
        fake.emit([proxy("personal-mac", host: "192.168.1.77")])
        await yieldUntil { manager.activeProxy?.host == "192.168.1.77" }

        XCTAssertTrue(manager.activeProxy?.isLive == true)
    }

    func testDiscoveryUpdatesRefreshTheRememberedEndpoint() async {
        let (manager, store, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac", host: "192.168.1.42")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac", host: "192.168.1.42"))

        fake.emit([proxy("personal-mac", host: "192.168.1.77")])
        await yieldUntil { store.config.settings.activeProxyHost == "192.168.1.77" }

        XCTAssertEqual(store.config.settings.activeProxyHost, "192.168.1.77")
    }

    func testReadingActiveProxyNeverWritesTheConfig() async {
        let (manager, store, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))
        let before = try! FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date

        // SwiftUI evaluates this during `body`; a write here would hit the disk on every render.
        for _ in 0..<20 { _ = manager.activeProxy }

        let after = try! FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        XCTAssertEqual(before, after)
    }

    func testVisibleProxiesIncludesTheRememberedActiveProxy() async {
        let (manager, _, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac")])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(proxy("personal-mac"))

        fake.emit([])
        await yieldUntil { manager.discovered.isEmpty }

        XCTAssertEqual(manager.visibleProxies.map(\.name), ["personal-mac"],
                       "a proxy that went quiet must not vanish from the list without explanation")
        XCTAssertFalse(manager.visibleProxies[0].isLive)
    }

    func testVisibleProxiesHasNoDuplicateWhenTheActiveProxyIsLive() async {
        let (manager, _, fake) = makeManagerKeepingStore()
        manager.startDiscovery()
        fake.emit([proxy("personal-mac"), proxy("laptop")])
        await yieldUntil { manager.discovered.count == 2 }
        manager.setActiveProxy(proxy("personal-mac"))

        XCTAssertEqual(manager.visibleProxies.count, 2)
    }
```

The existing `makeManager` returns the store as a tuple element that callers may drop; `ProxyManager.store` is **weak**, so a dropped binding deallocates it mid-test. Add this helper next to `makeManager` in the same class, and keep the store alive for its lifetime:

```swift
    /// Same as `makeManager`, but retains the store for the whole test — `ProxyManager.store` is
    /// weak (AppDelegate owns it in the app), so a dropped binding would silently deallocate it.
    private var retainedStore: CommandStore?

    private func makeManagerKeepingStore() -> (ProxyManager, CommandStore, FakeProxyDiscovering) {
        let made = makeManager()
        retainedStore = made.1
        return made
    }
```

Append to `DevDeckTests/ProxyManagerRoutingResolutionTests.swift` inside the existing class:

```swift
    func testRoutesThroughARememberedEndpoint() async {
        let (manager, store, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "personal-mac", host: "192.168.31.117", port: 9999,
                                  authRequired: false, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(manager.discovered[0])

        fake.emit([])   // corporate VPN blocks multicast; the proxy itself is still up
        await yieldUntil { manager.discovered.isEmpty }

        XCTAssertEqual(manager.routing(for: flagged()),
                       .routed(env: proxyEnv(host: "192.168.31.117", port: 9999, user: nil, pass: nil)))
        _ = store
    }

    func testRememberedAuthProxyWithoutCredentialsStaysUnavailable() async {
        let (manager, store, fake) = makeManager()
        manager.startDiscovery()
        fake.emit([DiscoveredProxy(name: "locked", host: "10.0.0.9", port: 8888,
                                  authRequired: true, exitIP: nil, proto: "http+socks", schema: 1)])
        await yieldUntil { manager.discovered.count == 1 }
        manager.setActiveProxy(manager.discovered[0])

        fake.emit([])
        await yieldUntil { manager.discovered.isEmpty }

        XCTAssertEqual(manager.routing(for: flagged()), .unavailable,
                       "caching the address must not smuggle past the credentials requirement")
        _ = store
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/ProxyManagerDiscoveryTests 2>&1 | grep -E "error:|Executed"`

Expected: compile failure — `value of type 'DiscoveredProxy' has no member 'isLive'`.

- [ ] **Step 3: Add `isLive` to `DiscoveredProxy`**

In `DevDeck/Proxy/ProxyDiscovery.swift`, after `let schema: Int`:

```swift
    /// False when this entry was rebuilt from the remembered endpoint rather than heard on the
    /// network. `var` with a default so every existing construction site keeps compiling.
    var isLive: Bool = true
```

- [ ] **Step 4: Implement the fallback in `ProxyManager`**

In `DevDeck/Proxy/ProxyManager.swift`, replace `activeProxy` with:

```swift
    /// The proxy chosen as active. Live Bonjour data wins; otherwise the last known endpoint is
    /// used, which is what keeps a flagged command working on networks that filter multicast
    /// (every corporate VPN) while leaving the proxy reachable over unicast TCP.
    ///
    /// Pure read: SwiftUI evaluates this during `body`, so it must never persist anything.
    var activeProxy: DiscoveredProxy? {
        guard let settings = store?.config.settings, let name = settings.activeProxyName else { return nil }
        if let live = discovered.first(where: { $0.name == name }) { return live }
        guard let host = settings.activeProxyHost, let port = settings.activeProxyPort else { return nil }
        return DiscoveredProxy(name: name, host: host, port: port,
                               authRequired: settings.activeProxyAuthRequired,
                               exitIP: nil, proto: "http+socks", schema: proxyTXTSchemaVersion,
                               isLive: false)
    }

    /// What the UI lists: everything currently announced, plus the active proxy when it is only
    /// remembered — otherwise a proxy that went quiet would vanish with no explanation.
    var visibleProxies: [DiscoveredProxy] {
        guard let active = activeProxy, !active.isLive else { return discovered }
        return discovered + [active]
    }
```

In `startDiscovery`, replace the loop body so a fresh result set refreshes the cache:

```swift
            for await set in stream {
                guard let self else { return }
                self.discovered = set
                self.rememberActiveEndpointIfLive()
                self.refreshCredentialCache()
            }
```

In `setActiveProxy(_:)`, persist the endpoint on selection — replace the final two lines of the non-nil branch with:

```swift
        let sameAsBefore = store?.config.settings.activeProxyName == proxy.name
        store?.setActiveProxy(name: proxy.name,
                              username: sameAsBefore ? store?.config.settings.activeProxyUsername : nil)
        store?.rememberActiveProxyEndpoint(host: proxy.host, port: proxy.port,
                                           authRequired: proxy.authRequired)
```

Add this private helper next to `refreshCredentialCache`:

```swift
    /// One of the two places the endpoint cache is written (the other is `setActiveProxy`).
    /// No-op unless the active proxy is in the current result set — a remembered entry must not
    /// rewrite itself.
    private func rememberActiveEndpointIfLive() {
        guard let name = store?.config.settings.activeProxyName,
              let live = discovered.first(where: { $0.name == name }) else { return }
        store?.rememberActiveProxyEndpoint(host: live.host, port: live.port,
                                           authRequired: live.authRequired)
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app just test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with [0-9]+ failure|TEST (SUCCEEDED|FAILED)" | tail -4`

Expected: `TEST SUCCEEDED`, 298 tests (289 + 9 new).

- [ ] **Step 6: Commit** (only if the user has asked for commits; otherwise skip and report)

```bash
git add DevDeck/Proxy/ProxyDiscovery.swift DevDeck/Proxy/ProxyManager.swift \
        DevDeckTests/ProxyManagerDiscoveryTests.swift DevDeckTests/ProxyManagerRoutingResolutionTests.swift
git commit -m "feat(proxy): fall back to the remembered endpoint when Bonjour goes quiet"
```

---

### Task 3: Show that the address is remembered

**Files:**
- Modify: `DevDeck/Localization/L10n.swift`
- Modify: `DevDeck/MenuBar/ProxySectionView.swift`
- Modify: `DevDeck/MainWindow/ProxyShareEditorView.swift`

**Interfaces:**
- Consumes: `ProxyManager.visibleProxies` and `DiscoveredProxy.isLive` from Task 2.
- Produces: nothing consumed by later tasks.

- [ ] **Step 1: Add the L10n string**

In `DevDeck/Localization/L10n.swift`, in the `// MARK: - Proxy manager` section next to `proxyNoneFound`:

```swift
    static var proxyLastKnownAddress: String {
        t("Last known address — not announced right now",
          "Последний известный адрес — сейчас не анонсируется")
    }
```

- [ ] **Step 2: List remembered proxies in the popover**

In `DevDeck/MenuBar/ProxySectionView.swift`, replace `discoveryRows` with:

```swift
    @ViewBuilder
    private var discoveryRows: some View {
        if proxy.visibleProxies.isEmpty {
            proxyNote(L10n.proxyNoneFound, icon: "antenna.radiowaves.left.and.right", color: .secondary)
        } else {
            ForEach(proxy.visibleProxies) { found in
                discoveredRow(found)
                if !found.isLive {
                    proxyNote(L10n.proxyLastKnownAddress, icon: "clock.arrow.circlepath", color: .secondary)
                }
            }
        }
    }
```

In the same file, dim the radio for a remembered entry — in `discoveredRow`, replace the `Image(systemName: isActive ? ...)` modifier chain's `.foregroundStyle(...)` line with:

```swift
                    .foregroundStyle(isActive ? (found.isLive ? Color.accentColor : Color.secondary)
                                              : Color.secondary)
```

Also update `rowCount` so the counter matches what is displayed:

```swift
    private var rowCount: Int {
        (shareEnabled ? 1 : 0) + (discoveryEnabled ? proxy.visibleProxies.count : 0)
    }
```

- [ ] **Step 3: List remembered proxies in the Proxy page**

In `DevDeck/MainWindow/ProxyShareEditorView.swift`, in `discoverySection`, replace the `else if proxy.discovered.isEmpty { ... } else { ForEach(proxy.discovered) ... }` branch with:

```swift
            } else if proxy.visibleProxies.isEmpty {
                Text(L10n.proxySearching).font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(proxy.visibleProxies) { found in
                    discoveredRow(found)
                }
            }
```

In `detail(for:)` in the same file, surface the state — replace its body with:

```swift
    private func detail(for found: DiscoveredProxy) -> String {
        guard found.isLive else {
            return "\(L10n.proxyEndpoint(found.host, found.port)) · \(L10n.proxyLastKnownAddress)"
        }
        var parts = [L10n.proxyEndpoint(found.host, found.port), found.proto]
        if let exitIP = found.exitIP { parts.append("\(L10n.proxyExitIP) \(exitIP)") }
        return parts.joined(separator: " · ")
    }
```

- [ ] **Step 4: Build and run the full suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app just test 2>&1 | grep -E "error:|Executed [0-9]+ tests, with [0-9]+ failure|TEST (SUCCEEDED|FAILED)" | tail -4`

Expected: `TEST SUCCEEDED`, 298 tests (Task 3 is view code, no new tests).

- [ ] **Step 5: Verify on the real machines**

This feature exists because of a live failure, so unit tests are not the acceptance criterion.

On the personal Mac (sharing, `192.168.31.117:9999`): leave DevDeck running.
On the work Mac:
1. With the corporate VPN **off**, confirm `macbook-pro-prokhor` is discovered and selected active.
2. Turn the corporate VPN **on**. Confirm `dns-sd -B _devdeck-proxy._tcp` returns nothing (multicast filtered).
3. Confirm the proxy row is **still listed** in DevDeck, dimmed, with "Последний известный адрес".
4. Run the flagged `proxy check` command → expect the 8 proxy variables and `78.40.193.132`.

Step 4 is the acceptance test: before this change it failed with "Нет активного прокси".

- [ ] **Step 6: Commit** (only if the user has asked for commits; otherwise skip and report)

```bash
git add DevDeck/Localization/L10n.swift DevDeck/MenuBar/ProxySectionView.swift \
        DevDeck/MainWindow/ProxyShareEditorView.swift
git commit -m "feat(ui): show the active proxy while it is only remembered"
```
