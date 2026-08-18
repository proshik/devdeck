# Remote Proxy over SSH Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route flagged commands, `dp`, and a dedicated browser window through a VDS over `ssh -D`, with nothing installed on the VDS: a local HTTP bridge (the built-in engine + SOCKS upstream) presents the tunnel as `http://127.0.0.1:<port>`.

**Architecture:** New client-side entity `RemoteProxy` (config) selectable alongside Bonjour proxies via `Settings.activeRemoteProxyID`. While selected, `ProxyManager` holds two daemons: the user-visible `ssh -N -D` tunnel command and a second synthetic built-in-engine daemon (the bridge) whose target dial goes through the SOCKS upstream. Everything downstream of `resolvedEndpoint()` is reused.

**Tech Stack:** Swift, Network.framework (`ProxyConfiguration(socksv5Proxy:)` via `NWParameters.PrivacyContext` — verified by spike 2026-08-18: hostnames are forwarded to the SOCKS server as ATYP=domain, no local DNS), XCTest.

**Spec:** `docs/superpowers/specs/2026-08-18-remote-proxy-design.md`

## Global Constraints

- Branch: `remote-proxy` off `main`.
- Test command: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'` (+ `-only-testing:DevDeckTests/<Class>`).
- File-system-synchronized Xcode groups — never edit `project.pbxproj`.
- No `schemaVersion` bump; every new config key decodes with a default.
- UI strings via `L10n.t("EN", "RU")`; the `dp` snippet stays English-only.
- Commits: conventional, no `Co-Authored-By`.
- `RunnerOutput` stream invariant unchanged; the bridge reuses the marker command `devdeck:proxy-listen -C <path>` — routing in `RoutingCommandRunner` needs NO change.

---

### Task 1: Model — `RemoteProxy`, selection exclusivity

**Files:**
- Modify: `DevDeck/Models/Config.swift` (Config + Settings), `DevDeck/Store/CommandStore.swift`
- Create: `DevDeck/Models/RemoteProxy.swift`
- Test: `DevDeckTests/RemoteProxyModelTests.swift`

**Interfaces (produced):**

```swift
struct RemoteProxy: Codable, Equatable, Identifiable {
    var id: UUID              // decodeIfPresent ?? UUID()
    var name: String          // required-ish: decodeIfPresent ?? ""
    var localPort: Int        // ?? 18888   (the bridge's HTTP port)
    var socksPort: Int        // ?? 1080    (ssh -D's port)
    var tunnelCommandID: UUID?
    static let bridgeDaemonID = UUID(uuidString: "6057D9E0-0000-4000-8000-000000000002")!
}
// Config: var remoteProxies: [RemoteProxy]   (CodingKeys + decodeIfPresent ?? [])
// Settings: var activeRemoteProxyID: UUID?   (decodeIfPresent ?? nil)
// CommandStore:
//   func upsertRemoteProxy(_ proxy: RemoteProxy)
//   func deleteRemoteProxy(id: UUID)          // also clears activeRemoteProxyID if it pointed there
//   func setActiveRemoteProxy(id: UUID?)      // non-nil → clears activeProxyName + endpoint cache
//   setActiveProxy(name:username:) additionally clears activeRemoteProxyID when name != nil
```

- [ ] **Step 1: Failing tests** (`RemoteProxyModelTests`): decode `{}` → defaults (18888/1080/nil); full round-trip through `Config`; `setActiveRemoteProxy(id:)` clears `activeProxyName`, `activeProxyHost/Port/LANPrefix`; `setActiveProxy(name:)` clears `activeRemoteProxyID`; `deleteRemoteProxy` of the active one clears the selection. Build store instances the way `CommandStoreTests` does (temp `configURL`).
- [ ] **Step 2: Run** `-only-testing:DevDeckTests/RemoteProxyModelTests` — expect compile failure.
- [ ] **Step 3: Implement** — mirror `ProxyShare`'s resilient-decoding style; store mutations mirror `setActiveProxy`'s save-and-publish pattern.
- [ ] **Step 4: Run** the class + `CommandStoreTests` + `ProxyManagerShareTests` — PASS.
- [ ] **Step 5: Commit** `feat(proxy): RemoteProxy model and exclusive selection`

---

### Task 2: Bridge plumbing — SOCKS upstream in the built-in engine

**Files:**
- Modify: `DevDeck/Proxy/BuiltInProxyConfig.swift`, `DevDeck/Proxy/BuiltInProxyListener.swift`, `DevDeck/Proxy/BuiltInProxyRunner.swift`
- Create: `DevDeckTests/Support/FakeSOCKSServer.swift`
- Test: `DevDeckTests/BuiltInProxyConfigTests.swift`, `DevDeckTests/BuiltInProxyListenerTests.swift`

**Interfaces (produced):**

```swift
// Config read-back grows a third slot; existing callers updated:
func parseBuiltInProxyConfig(_ data: Data) -> (port: Int, auth: GostAuth?, upstreamSocks: String?)?
// Pure writer for the bridge's generated file (same shape as gostConfigJSON + one extension key):
func bridgeConfigJSON(localPort: Int, socksPort: Int) -> String?
//   {"services":[{"addr":":18888","handler":{"type":"auto"},"listener":{"type":"tcp"},
//    "name":"devdeck-bridge"}],"upstreamSocks":"127.0.0.1:1080"}   (sortedKeys)
// Listener: init(port: UInt16, auth: GostAuth?, upstream: NWEndpoint? = nil,
//                emit: @escaping @Sendable (RunnerOutput) -> Void)
```

Dial change in `ProxyConnection` (the ONLY behavioral change): when `upstream != nil`, build the
target's `NWParameters` with

```swift
let params = NWParameters.tcp
if let upstream {
    let proxy = ProxyConfiguration(socksv5Proxy: upstream)
    let context = NWParameters.PrivacyContext(description: "devdeck-bridge")
    context.proxyConfigurations = [proxy]
    params.setPrivacyContext(context)
}
let target = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: params)
```

`GostConfig` gains `let upstreamSocks: String?` (encoded only by the bridge writer; absent in the
share's config, so the share path is bit-identical — asserted by the existing verbatim JSON
tests). `BuiltInProxyRunner` parses the upstream and passes it through.

`FakeSOCKSServer` (test support): NWListener on an ephemeral port; on connection performs the
SOCKS5 no-auth handshake, records `(atyp, address, port)` thread-safely, replies success, then
**serves the tunnel itself** (echoes bytes back) — no onward dial, so the test controls both ends.

- [ ] **Step 1: Failing tests** — config: round-trip `bridgeConfigJSON` through the parser (port + upstream, `auth == nil`); share configs still parse with `upstreamSocks == nil`. Listener (loopback): bridge with `upstream:` at the fake SOCKS server; raw client sends `CONNECT devdeck-spike.test:4444 HTTP/1.1` → expect `200`, echoed payload, and the fake recorded `atyp == .domain, address == "devdeck-spike.test", port == 4444` — the hostname must reach SOCKS unresolved.
- [ ] **Step 2: Run** both classes — expect compile failure.
- [ ] **Step 3: Implement** as specified above.
- [ ] **Step 4: Run** `BuiltInProxyConfigTests`, `BuiltInProxyListenerTests`, `BuiltInProxyRunnerTests`, `ProxyShareMappingTests` — PASS.
- [ ] **Step 5: Commit** `feat(proxy): SOCKS upstream in the built-in engine`

---

### Task 3: Tunnel command + `ProxyManager` remote lifecycle

**Files:**
- Modify: `DevDeck/Models/RemoteProxy.swift`, `DevDeck/Proxy/ProxyManager.swift`, `DevDeck/AppDelegate.swift`, `DevDeck/Localization/L10n.swift`
- Test: `DevDeckTests/ProxyManagerRemoteTests.swift`

**Interfaces (produced):**

```swift
// RemoteProxy:
func makeTunnelCommand(destination: String) -> Command
//   Command(id: UUID(), name: L10n.proxyTunnelCommandName(name),
//           command: "ssh -N -D 127.0.0.1:\(socksPort) \(destination)",
//           isDaemon: true, watchdogEnabled: true, port: socksPort)
func bridgeCommand(configPath: String) -> Command
//   Command(id: Self.bridgeDaemonID, name: L10n.proxyBridgeDaemonName,
//           command: ProxyShare.builtInCommandPrefix + configPath,
//           isDaemon: true, watchdogEnabled: true, port: localPort)
// ProxyManager:
var activeRemoteProxy: RemoteProxy?              // from store, by activeRemoteProxyID
func setActiveRemoteProxy(_ proxy: RemoteProxy?) // exclusivity + start/stop both daemons
func addRemoteProxy(name:destination:localPort:socksPort:)  // creates+links the tunnel command
func deleteRemoteProxy(_ proxy: RemoteProxy, alsoTunnelCommand: Bool)
// init gains: bridgeConfigFile: any PrivateFileWriting = LivePrivateFile(url: RemoteProxy.bridgeConfigURL)
// RemoteProxy.bridgeConfigURL = Application Support/DevDeck/proxy-bridge.json
```

Behavior:
- `startRemote()` (private, mirror of `startShare`): write `bridgeConfigJSON` → start the linked
  tunnel command (skip if already `daemonRunning`) and the bridge command; arm the existing
  daemon-state observation (it already re-fires per state change; extend `observeDaemonState`'s
  tracked read to the two remote ids). `stopRemote()`: stop both, remove `proxy-bridge.json`.
- `start()` (launch): if `activeRemoteProxyID` set → `startRemote()`.
- `activeProxy`: when a remote proxy is active, return the synthetic
  `DiscoveredProxy(name:, host: "127.0.0.1", port: localPort, authRequired: false, exitIP: nil,
  proto: "http", schema: proxyTXTSchemaVersion, isLive: bothDaemonsRunning)`.
- `resolvedEndpoint()`: remote kind → nil unless tunnel AND bridge are `.daemonRunning`.
- `refreshProxyEnvFile()`: remote kind → skip the `lanIP()` guard, write with `lanPrefix: "*"`.
- `AppDelegate` quit filter: also exclude `RemoteProxy.bridgeDaemonID` (in-process listener);
  the tunnel command is a real ssh and keeps normal daemon semantics.
- L10n: `proxyTunnelCommandName(_ name: String)` → `t("SSH tunnel: \(name)", "SSH-туннель: \(name)")`,
  `proxyBridgeDaemonName` → `t("Proxy bridge", "Прокси-мост")`.

- [ ] **Step 1: Failing tests** (`ProxyManagerRemoteTests`, rig copied from `ProxyManagerShareTests` with `bridgeConfigFile: FakePrivateFile`): `addRemoteProxy` creates a linked daemon command with the exact ssh string and flags; select → both commands started via the fake runner, bridge config on "disk" contains `"upstreamSocks":"127.0.0.1:1080"`; `routing(for:)` on a flagged command → `.unavailable` while the tunnel controller hasn't `started()`, `.routed` with env `http://127.0.0.1:18888` once both are up; env file written with `DEVDECK_PROXY_LAN=*` even when `lanIP: { nil }`; deselect → both stopped, bridge config removed, env file removed; selecting a discovered proxy stops the remote pair.
- [ ] **Step 2: Run** — expect compile failure.
- [ ] **Step 3: Implement** per the behavior list; follow `startShare`/`stopShare`/`syncAdvertising` patterns (no advertising for remote — nothing to announce).
- [ ] **Step 4: Run** `ProxyManagerRemoteTests` + `ProxyManagerShareTests` + `ProxyRoutingTests` — PASS.
- [ ] **Step 5: Commit** `feat(proxy): remote proxy lifecycle — tunnel plus bridge held while selected`

---

### Task 4: `dp` wildcard scope

**Files:**
- Modify: `DevDeck/Proxy/ProxyShellHelper.swift`
- Test: `DevDeckTests/ProxyRoutingTests.swift` (or wherever the snippet/env tests live — `grep -rn proxyShellHelperSnippet DevDeckTests/`)

The snippet's network check gains one leading clause:

```
[[ $lan == "*" ]] || { [[ -n $ip && ${ip%.*} == $lan ]] || { print -u2 "dp: proxy $lan is not on this network"; return 1; }; }
```

(and the `for iface` loop moves under the same guard if that reads cleaner — behavior: `lan == "*"` skips the interface scan entirely).

- [ ] **Step 1: Failing test** — snippet contains the `"*"` guard; `proxyEnvFileContents(url:, lanPrefix: "*")` renders `DEVDECK_PROXY_LAN=*`.
- [ ] **Step 2–4:** red → implement → green (snippet tests + full proxy test classes).
- [ ] **Step 5: Commit** `feat(proxy): dp helper accepts network-independent loopback proxies`

---

### Task 5: Browser via proxy

**Files:**
- Create: `DevDeck/Proxy/ProxyBrowser.swift`
- Modify: `DevDeck/Proxy/ProxyManager.swift`
- Test: `DevDeckTests/ProxyBrowserTests.swift`

```swift
/// Pure: the argument vector for a proxied Chrome instance.
func proxyBrowserArguments(proxyURL: String, profileDir: String) -> [String]
// ["--proxy-server=<url>", "--proxy-bypass-list=localhost;127.0.0.1", "--user-data-dir=<dir>"]
let proxyBrowserProfileURL: URL   // Application Support/DevDeck/ProxyBrowser
let proxyBrowserChromePath = "/Applications/Google Chrome.app"
// ProxyManager:
var canOpenProxyBrowser: Bool       // resolvedEndpoint() != nil
func openProxyBrowser()             // launcher injected: (URL app, [String] args) -> Bool
```

Live launcher: `NSWorkspace.shared.openApplication(at:configuration:)` with
`NSWorkspace.OpenConfiguration` (`createsNewApplicationInstance = true`, `arguments = args`).
Chrome bundle missing → `DiagnosticLog` warn + alert string via L10n (the UI shows it in Task 6).

- [ ] **Step 1: Failing tests** — argument builder verbatim; `openProxyBrowser()` passes the resolved URL and profile dir to the injected launcher; no-op (and no launcher call) when nothing resolves.
- [ ] **Step 2–4:** red → implement → green.
- [ ] **Step 5: Commit** `feat(proxy): proxied Chrome instance for browser logins`

---

### Task 6: UI

**Files:**
- Modify: `DevDeck/MainWindow/ProxyShareEditorView.swift`, `DevDeck/MenuBar/ProxySectionView.swift`, `DevDeck/Localization/L10n.swift`

- **Proxy page, discovery section**: after the discovered rows, a "Remote proxies (SSH)" block —
  one selectable row per `RemoteProxy` (same radio affordance; caption `127.0.0.1:<port> · via
  SSH tunnel`, tunnel-state dot from `processManager.states`), an "Add remote proxy…" button
  opening a sheet: name, ssh destination, local port (18888), SOCKS port (1080) → calls
  `proxy.addRemoteProxy(…)`. Row context: reveal/edit ports, delete (confirm; offers deleting
  the tunnel command). Destination is asked only at creation — afterwards the command is the
  source of truth (a "show tunnel command" link).
- **Browser button**: next to the check button (both views), enabled by `canOpenProxyBrowser`;
  Chrome-missing alert text.
- **Popover**: remote proxy rows join the existing list rendering in `ProxySectionView` (same
  selection tap → `setActiveRemoteProxy`); the bridge and tunnel daemons already appear as
  daemon rows for free.
- L10n: EN/RU for every new string (`proxyRemoteSection`, `proxyRemoteAdd`, `proxyRemoteVia`,
  `proxyBrowserButton`, `proxyBrowserChromeMissing`, sheet field labels, delete-confirm).

- [ ] **Step 1: Implement** (UI is not unit-tested here).
- [ ] **Step 2: Build** — `xcodebuild build … | tail` → `BUILD SUCCEEDED`.
- [ ] **Step 3: Commit** `feat(proxy): remote proxy UI and the browser button`

---

### Task 7: Docs, full suite, dogfood

- [ ] **Step 1: Full suite** — `TEST SUCCEEDED`, report pass/fail counts.
- [ ] **Step 2: Docs** — README: "Remote proxy (VDS over SSH)" subsection under Proxy Manager (needs only `sshd` on the VDS; the `/login` browser flow; the `dp` snippet changed — re-paste). CHANGELOG: Unreleased entry (remote proxies, browser button, dp snippet version note).
- [ ] **Step 3: Manual dogfood with the user's real VDS** — create the remote proxy in the UI, select it, check button shows the VDS's public IP, `dp curl -s api.ipify.org` agrees, browser button opens proxied Chrome (claude.ai reachable), flagged `claude` runs `/login` end-to-end. Coordinate with the user — this needs their ssh destination and their click-through; report the transcript honestly.
- [ ] **Step 4: Commit** `docs: remote proxy over SSH`

## Self-Review

- **Spec coverage:** Part 1 → Task 1 (+3 for creation flow); Part 2 → Tasks 3, 4; Part 3 → Tasks 2, 3 (spike already executed — recorded in the header); Part 4 → Task 5 (+6 button); Part 5 → Task 6; Part 6 → per-task tests + Task 7. The spec's fallback section needs no task — the spike passed.
- **Placeholder scan:** Task 6 is implementation-guided without code blocks (SwiftUI view work in files whose structure the executor reads in place — same convention as the previous plan's UI task); everywhere else interfaces and behaviors are explicit.
- **Type consistency:** `RemoteProxy.bridgeDaemonID`, `parseBuiltInProxyConfig` 3-tuple, `bridgeConfigJSON(localPort:socksPort:)`, `makeTunnelCommand(destination:)`, `upstream: NWEndpoint?`, `"*"` prefix — names match across tasks.
