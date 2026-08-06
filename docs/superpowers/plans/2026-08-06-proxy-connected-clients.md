# Connected Clients on the Proxy Host — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The machine sharing its VPN egress shows which machines are using the share right now and which used it in the last few minutes.

**Architecture:** The `gost` listener already streams JSON to stderr through `ProcessManager`. A pure parser turns each line into a session-opened/closed fact; an `@Observable` monitor folds those facts into a per-IP list with two time windows (active / retained); a reverse-DNS resolver names the IPs. `ProcessManager` gains one generic output hook — wired by `AppDelegate` to `ProxyManager`, exactly as `proxyRouting` already is — so it stays unaware that proxies exist.

**Tech Stack:** Swift 5, SwiftUI + AppKit, `@Observable`, XCTest. Xcode project `DevDeck.xcodeproj`, scheme `DevDeck`.

**Spec:** `docs/superpowers/specs/2026-08-06-proxy-connected-clients-design.md`

## Global Constraints

- **Test command** — `xcodebuild` needs an explicit developer dir on this machine, `xcode-select` points at CommandLineTools:
  ```
  DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
    -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'
  ```
  Add `-only-testing:DevDeckTests/<ClassName>` to run a single class.
- **Commit once per task**, on the branch `feat/proxy-connected-clients` (the user authorised this for
  this plan; `main` is not touched). Message style follows the repo's history —
  `feat(proxy): …`, `test(proxy): …`, `feat(ui): …`. **Never** add a `Co-Authored-By` trailer or any
  other attribution line: the user's global instructions forbid it. A task's commit lands only after
  its tests pass.
- **No `project.pbxproj` edits.** Both targets are `PBXFileSystemSynchronizedRootGroup`; new files under `DevDeck/` and `DevDeckTests/` are picked up automatically.
- **Comment language — English.** Every file in the project is commented in English; match it.
- **User-facing strings go through `L10n`,** with both an English and a Russian value, in `DevDeck/Localization/L10n.swift`. Never hard-code a string in a view.
- **Never read `inputBytes`, `outputBytes`, `host` or `dst` from a gost line.** The feature deliberately does not account traffic and does not look at where peers go.
- **Loopback is never a client.** `127.0.0.1` and `::1` are this machine's own exit-IP probe and its local `dp`, not another machine.
- **Time windows:** active = 120 s, retention = 600 s, name-retry = 300 s, publish coalescing = 500 ms, sweep = 15 s. All injectable, these are the defaults.

---

### Task 1: `parseGostLogLine` — the log parser

**Files:**
- Create: `DevDeck/Proxy/ProxyClientLog.swift`
- Test: `DevDeckTests/ProxyClientLogTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `enum ProxyClientEvent { case sessionOpened(client: String, sid: String); case sessionClosed(sid: String) }`,
  `func parseGostLogLine(_ line: String) -> ProxyClientEvent?`,
  `func proxyClientIP(_ client: String) -> String?`. Task 3 calls both functions.

- [ ] **Step 1: Write the failing tests**

Create `DevDeckTests/ProxyClientLogTests.swift`:

```swift
import XCTest
@testable import DevDeck

/// The gost log parser. Every sample below was captured verbatim from `gost 3.2.6` driving a real
/// listener, so a format change in a future gost breaks these tests rather than the UI silently.
final class ProxyClientLogTests: XCTestCase {

    private let opened = """
        {"client":"192.168.31.42:55904","handler":"http","kind":"handler","level":"info",\
        "listener":"tcp","local":"192.168.31.5:9999","msg":"192.168.31.42:55904 <> 192.168.31.5:9999",\
        "network":"","remote":"192.168.31.42:55904","service":"devdeck-proxy","sid":"d9q51fl1837ipckfutrg",\
        "time":"2026-08-06T12:15:42.246+03:00"}
        """

    private let closed = """
        {"client":"192.168.31.42:55904","duration":435225125,"handler":"http","inputBytes":706,\
        "kind":"handler","level":"info","listener":"tcp","local":"192.168.31.5:9999",\
        "msg":"192.168.31.42:55904 >< 192.168.31.5:9999","network":"","outputBytes":3105,\
        "remote":"192.168.31.42:55904","service":"devdeck-proxy","sid":"d9q51fl1837ipckfutrg",\
        "time":"2026-08-06T12:15:42.681+03:00"}
        """

    /// A dial to ONE destination inside a live session — must not be counted as a second session.
    private let dialed = """
        {"client":"192.168.31.42:55904","clientID":"","dst":"104.26.13.205:443","handler":"http",\
        "host":"api.ipify.org:443","kind":"handler","level":"info","listener":"tcp",\
        "local":"192.168.31.5:9999","msg":"192.168.31.42:55904 <-> api.ipify.org:443","network":"tcp",\
        "remote":"192.168.31.42:55904","service":"devdeck-proxy","sid":"d9q51fl1837ipckfutrg",\
        "time":"2026-08-06T12:15:42.384+03:00"}
        """

    private let dialClosed = """
        {"client":"192.168.31.42:55904","clientID":"","dst":"104.26.13.205:443","duration":297735250,\
        "handler":"http","host":"api.ipify.org:443","kind":"handler","level":"info","listener":"tcp",\
        "local":"192.168.31.5:9999","msg":"192.168.31.42:55904 >-< api.ipify.org:443","network":"tcp",\
        "remote":"192.168.31.42:55904","service":"devdeck-proxy","sid":"d9q51fl1837ipckfutrg",\
        "time":"2026-08-06T12:15:42.681+03:00"}
        """

    private let startup = """
        {"handler":"auto","kind":"service","level":"info","listener":"tcp",\
        "msg":"listening on [::]:9999/tcp","service":"devdeck-proxy",\
        "time":"2026-08-06T12:15:40.248+03:00"}
        """

    func testSessionOpenIsRecognized() {
        XCTAssertEqual(parseGostLogLine(opened),
                       .sessionOpened(client: "192.168.31.42:55904", sid: "d9q51fl1837ipckfutrg"))
    }

    func testSessionCloseIsRecognized() {
        XCTAssertEqual(parseGostLogLine(closed), .sessionClosed(sid: "d9q51fl1837ipckfutrg"))
    }

    func testDestinationDialsAreIgnored() {
        XCTAssertNil(parseGostLogLine(dialed), "‘<->’ is a dial inside a session, not a new session")
        XCTAssertNil(parseGostLogLine(dialClosed), "‘>-<’ closes a destination, not the session")
    }

    func testServiceLinesAndGarbageAreIgnored() {
        XCTAssertNil(parseGostLogLine(startup))
        XCTAssertNil(parseGostLogLine(""))
        XCTAssertNil(parseGostLogLine("gost: command not found"))
        XCTAssertNil(parseGostLogLine("{\"client\":\"1.2.3.4:5\",\"msg\":\"1.2.3.4:5 <> x\"}"),
                     "no sid → not a session event")
    }

    func testClientIPDropsTheEphemeralPort() {
        XCTAssertEqual(proxyClientIP("192.168.31.42:55904"), "192.168.31.42")
    }

    func testClientIPUnwrapsIPv6() {
        XCTAssertEqual(proxyClientIP("[fe80::1%en0]:55904"), "fe80::1%en0")
    }

    func testClientIPRejectsGarbage() {
        XCTAssertNil(proxyClientIP("192.168.31.42"), "no port → not a gost client string")
        XCTAssertNil(proxyClientIP(":55904"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' \
  -only-testing:DevDeckTests/ProxyClientLogTests
```

Expected: compile failure — `cannot find 'parseGostLogLine' in scope`.

- [ ] **Step 3: Write the implementation**

Create `DevDeck/Proxy/ProxyClientLog.swift`:

```swift
import Foundation

/// One fact extracted from a `gost` log line — the only thing DevDeck reads out of the listener's
/// output. Deliberately narrow: no byte counters, no destination hosts.
enum ProxyClientEvent: Equatable {
    /// `client` is the peer's `IP:port`, exactly as gost reports it.
    case sessionOpened(client: String, sid: String)
    case sessionClosed(sid: String)
}

/// Parse one line of `gost` v3 JSON output.
///
/// A session's lifetime is two lines carrying the same `sid`:
///
///     {"client":"192.168.31.42:55904","msg":"192.168.31.42:55904 <> 192.168.31.5:9999","sid":"d9q…"}
///     {"client":"192.168.31.42:55904","msg":"192.168.31.42:55904 >< 192.168.31.5:9999","sid":"d9q…"}
///
/// The ` <-> ` / ` >-< ` pair in between is a dial to ONE destination inside that session. Those
/// lines are ignored: counting them would multiply one peer into many sessions, and their
/// `host`/`dst` fields are somebody else's browsing history, which this feature does not read.
/// The spaces around the separators are what distinguishes ` <> ` from ` <-> `.
///
/// Anything that is not an object with string `client`, `sid` and `msg` returns nil — gost's own
/// startup lines, non-JSON output, and any future format change all fail closed into "no data"
/// rather than into a wrong list.
func parseGostLogLine(_ line: String) -> ProxyClientEvent? {
    guard let data = line.data(using: .utf8),
          let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
          let client = object["client"] as? String, !client.isEmpty,
          let sid = object["sid"] as? String, !sid.isEmpty,
          let msg = object["msg"] as? String else { return nil }
    if msg.contains(" >< ") { return .sessionClosed(sid: sid) }
    if msg.contains(" <> ") { return .sessionOpened(client: client, sid: sid) }
    return nil
}

/// The peer's address without its ephemeral port — the identity a machine is grouped by.
///
/// gost reports `IP:port`, and an IPv6 peer arrives bracketed (`[fe80::1%en0]:55904`), so the split
/// is at the LAST colon and the brackets are unwrapped.
func proxyClientIP(_ client: String) -> String? {
    guard let colon = client.lastIndex(of: ":") else { return nil }
    var host = String(client[client.startIndex..<colon])
    if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
    return host.isEmpty ? nil : host
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' \
  -only-testing:DevDeckTests/ProxyClientLogTests
```

Expected: all 7 tests pass.

---

### Task 2: `ProxyClientNaming` — turning an IP into a machine name

**Files:**
- Create: `DevDeck/Proxy/ProxyClientNaming.swift`
- Test: `DevDeckTests/ProxyClientNamingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `protocol ProxyClientNaming: Sendable { func hostname(for ip: String) async -> String? }`,
  `struct ReverseDNSClientNaming: ProxyClientNaming`,
  `func reverseLookup(_ ip: String) -> String?`,
  `func shortHostName(_ raw: String) -> String`. Task 3 injects a `ProxyClientNaming`.

- [ ] **Step 1: Write the failing tests**

Create `DevDeckTests/ProxyClientNamingTests.swift`:

```swift
import XCTest
@testable import DevDeck

/// Reverse naming of a peer. The pure shortening is covered exhaustively; the resolver itself is
/// exercised only where the answer is deterministic on any Mac (`/etc/hosts`) or needs no resolver
/// at all (malformed input), so the suite never waits on DNS.
final class ProxyClientNamingTests: XCTestCase {

    func testTrailingDotIsTrimmed() {
        XCTAssertEqual(shortHostName("macbook-vasya.local."), "macbook-vasya")
    }

    func testLocalSuffixIsTrimmed() {
        XCTAssertEqual(shortHostName("macbook-vasya.local"), "macbook-vasya")
    }

    func testOtherNamesSurviveIntact() {
        XCTAssertEqual(shortHostName("build-01.office.example.com"), "build-01.office.example.com")
        XCTAssertEqual(shortHostName("localhost"), "localhost")
    }

    func testMalformedAddressResolvesToNothing() {
        XCTAssertNil(reverseLookup("not-an-ip"))
        XCTAssertNil(reverseLookup(""))
    }

    func testLoopbackResolvesThroughTheHostsFile() {
        XCTAssertEqual(reverseLookup("127.0.0.1"), "localhost")
    }

    func testLiveNamingRunsOffTheCallersThread() async {
        let name = await ReverseDNSClientNaming().hostname(for: "127.0.0.1")
        XCTAssertEqual(name, "localhost")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' \
  -only-testing:DevDeckTests/ProxyClientNamingTests
```

Expected: compile failure — `cannot find 'shortHostName' in scope`.

- [ ] **Step 3: Write the implementation**

Create `DevDeck/Proxy/ProxyClientNaming.swift`:

```swift
import Foundation

/// Resolves a peer's IP to something a human recognizes. Behind a protocol (the probe pattern used
/// everywhere in this subsystem) so the monitor is unit-tested without mDNS.
protocol ProxyClientNaming: Sendable {
    /// nil when the address has no name — the caller shows the bare IP, which is never worse.
    func hostname(for ip: String) async -> String?
}

/// Reverse lookup through the system resolver.
///
/// No `dns-sd` subprocess is needed: macOS answers `.local` reverse queries out of mDNSResponder,
/// so a Mac on the same LAN resolves with no DNS server involved.
struct ReverseDNSClientNaming: ProxyClientNaming {
    func hostname(for ip: String) async -> String? {
        // getnameinfo blocks for as long as the resolver takes — never on the main thread.
        await Task.detached(priority: .utility) { reverseLookup(ip) }.value
    }
}

/// Blocking reverse lookup. The caller MUST keep it off the main thread.
///
/// IPv4 only: the share is announced over an IPv4 address (`pickLANIPv4`), so a peer arriving over
/// IPv6 is an oddity — it gets nil here and is shown by its address.
func reverseLookup(_ ip: String) -> String? {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    guard ip.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else { return nil }

    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let status = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                        &host, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
        }
    }
    guard status == 0 else { return nil }   // NI_NAMEREQD → an unnamed address is an error, not a digit string
    let name = shortHostName(String(cString: host))
    return name.isEmpty ? nil : name
}

/// Trim the resolver's trailing dot and the `.local` Bonjour suffix — the same shortening
/// `ProxyShare.defaultServiceName` applies to this machine's own host name.
func shortHostName(_ raw: String) -> String {
    var name = raw
    if name.hasSuffix(".") { name = String(name.dropLast()) }
    if name.hasSuffix(".local") { name = String(name.dropLast(6)) }
    return name
}
```

- [ ] **Step 4: Run the tests to verify they pass**

```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' \
  -only-testing:DevDeckTests/ProxyClientNamingTests
```

Expected: all 6 tests pass.

---

### Task 3: `ProxyClientMonitor` — the list of machines

**Files:**
- Create: `DevDeck/Proxy/ProxyClientMonitor.swift`
- Create: `DevDeckTests/Support/FakeProxyClientNaming.swift`
- Test: `DevDeckTests/ProxyClientMonitorTests.swift`

**Interfaces:**
- Consumes: `parseGostLogLine`, `proxyClientIP` (Task 1); `ProxyClientNaming`, `ReverseDNSClientNaming` (Task 2).
- Produces: `@MainActor @Observable final class ProxyClientMonitor` with
  `struct Client: Identifiable, Equatable { let ip: String; var hostname: String?; var liveSessions: Int; let firstSeen: Date; var lastSeen: Date; var isActive: Bool; var displayName: String }`,
  `private(set) var clients: [Client]`, `var activeCount: Int`,
  `func ingest(_ line: String)`, `func listenerDidStart()`, `func clear()`, `func publishNow()`, `func sweepNow()`.
  Task 4 owns an instance; Tasks 5 and 6 render `clients` and `activeCount`.

- [ ] **Step 1: Write the fake resolver**

Create `DevDeckTests/Support/FakeProxyClientNaming.swift`:

```swift
import Foundation
@testable import DevDeck

/// Scripted reverse naming — no mDNS, no waiting. An IP absent from `names` resolves to nothing,
/// which is how a real unnamed peer behaves.
final class FakeProxyClientNaming: ProxyClientNaming, @unchecked Sendable {
    private let lock = NSLock()
    private var names: [String: String]
    private var _calls: [String] = []

    init(names: [String: String] = [:]) {
        self.names = names
    }

    /// Every IP this resolver was asked about, in order — asserts the retry policy.
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    func hostname(for ip: String) async -> String? {
        lock.lock(); defer { lock.unlock() }
        _calls.append(ip)
        return names[ip]
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `DevDeckTests/ProxyClientMonitorTests.swift`:

```swift
import XCTest
@testable import DevDeck

/// Host-side view of who is using the share. Every window is driven by an injected clock and the
/// publish/sweep steps are invoked directly, so the suite has no sleeps and no timing flake.
@MainActor
final class ProxyClientMonitorTests: XCTestCase {

    /// Mutable clock — `ProxyClientMonitor` reads the time through a closure.
    private final class TestClock {
        var now = Date(timeIntervalSince1970: 1_000_000)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    private var clock: TestClock!
    private var naming: FakeProxyClientNaming!

    override func setUp() {
        super.setUp()
        clock = TestClock()
        naming = FakeProxyClientNaming(names: ["192.168.31.42": "macbook-vasya"])
    }

    /// Sweep and publish intervals are pushed out of the way — the tests call `sweepNow()` and
    /// `publishNow()` themselves.
    private func makeMonitor() -> ProxyClientMonitor {
        let clock = clock!
        return ProxyClientMonitor(naming: naming,
                                  now: { clock.now },
                                  publishInterval: .seconds(3600),
                                  sweepInterval: .seconds(3600))
    }

    private func openLine(_ client: String, sid: String) -> String {
        """
        {"client":"\(client)","kind":"handler","level":"info","local":"192.168.31.5:9999",\
        "msg":"\(client) <> 192.168.31.5:9999","service":"devdeck-proxy","sid":"\(sid)"}
        """
    }

    private func closeLine(_ client: String, sid: String) -> String {
        """
        {"client":"\(client)","kind":"handler","level":"info","local":"192.168.31.5:9999",\
        "msg":"\(client) >< 192.168.31.5:9999","service":"devdeck-proxy","sid":"\(sid)"}
        """
    }

    func testTwoSessionsFromOneMachineAreOneClient() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.ingest(openLine("192.168.31.42:1001", sid: "b"))
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.count, 1)
        XCTAssertEqual(monitor.clients.first?.ip, "192.168.31.42")
        XCTAssertEqual(monitor.clients.first?.liveSessions, 2)
        XCTAssertEqual(monitor.activeCount, 1)
    }

    func testClosingOneSessionLeavesTheOther() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.ingest(openLine("192.168.31.42:1001", sid: "b"))
        monitor.ingest(closeLine("192.168.31.42:1000", sid: "a"))
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.first?.liveSessions, 1)
    }

    func testTwoMachinesAreTwoClients() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.ingest(openLine("192.168.31.77:2000", sid: "b"))
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.count, 2)
        XCTAssertEqual(monitor.activeCount, 2)
    }

    func testAnIdleMachineStaysActiveInsideTheWindow() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.ingest(closeLine("192.168.31.42:1000", sid: "a"))

        clock.advance(60)   // inside the 120 s active window
        monitor.publishNow()
        XCTAssertEqual(monitor.clients.first?.liveSessions, 0)
        XCTAssertTrue(monitor.clients.first?.isActive == true,
                      "proxy sessions are short — a quiet minute is not a disconnect")
        XCTAssertEqual(monitor.activeCount, 1)

        clock.advance(120)  // now past it
        monitor.publishNow()
        XCTAssertFalse(monitor.clients.first?.isActive == true)
        XCTAssertEqual(monitor.activeCount, 0)
        XCTAssertEqual(monitor.clients.count, 1, "still listed, just no longer active")
    }

    func testAnIdleMachineIsSweptAfterTheRetentionWindow() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.ingest(closeLine("192.168.31.42:1000", sid: "a"))

        clock.advance(599)
        monitor.sweepNow()
        XCTAssertEqual(monitor.clients.count, 1)

        clock.advance(2)
        monitor.sweepNow()
        XCTAssertTrue(monitor.clients.isEmpty)
    }

    func testAMachineWithLiveSessionsIsNeverSwept() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))

        clock.advance(3600)
        monitor.sweepNow()
        XCTAssertEqual(monitor.clients.count, 1)
    }

    func testListenerRestartDropsLiveSessionsButKeepsTheMachine() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.listenerDidStart()
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.count, 1, "who was just here survives a watchdog restart")
        XCTAssertEqual(monitor.clients.first?.liveSessions, 0,
                       "the process that owned those sessions is gone")
    }

    func testSessionsFromBeforeARestartDoNotGoNegative() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.listenerDidStart()
        monitor.ingest(closeLine("192.168.31.42:1000", sid: "a"))
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.first?.liveSessions, 0)
    }

    func testClearRemovesEverything() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.clear()

        XCTAssertTrue(monitor.clients.isEmpty)
        XCTAssertEqual(monitor.activeCount, 0)
    }

    func testLoopbackIsNotAMachine() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("127.0.0.1:1000", sid: "a"))
        monitor.ingest(openLine("[::1]:1001", sid: "b"))
        monitor.publishNow()

        XCTAssertTrue(monitor.clients.isEmpty, "our own exit-IP probe is not another machine")
    }

    func testUnparsableLinesChangeNothing() {
        let monitor = makeMonitor()
        monitor.ingest("gost: something went wrong")
        monitor.ingest("")
        monitor.publishNow()

        XCTAssertTrue(monitor.clients.isEmpty)
    }

    func testAResolvedNameReachesTheClient() async {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        await sleepUntil({ self.naming.calls == ["192.168.31.42"] },
                         message: "the resolver was never asked")
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.first?.hostname, "macbook-vasya")
        XCTAssertEqual(monitor.clients.first?.displayName, "macbook-vasya")
    }

    func testAnUnresolvedMachineIsShownByItsAddress() async {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.99:1000", sid: "a"))
        await sleepUntil({ self.naming.calls == ["192.168.31.99"] },
                         message: "the resolver was never asked")
        monitor.publishNow()

        XCTAssertNil(monitor.clients.first?.hostname)
        XCTAssertEqual(monitor.clients.first?.displayName, "192.168.31.99")
    }

    func testAFailedLookupIsNotRetriedOnEveryRequest() async {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.99:1000", sid: "a"))
        await sleepUntil({ self.naming.calls.count == 1 }, message: "the resolver was never asked")

        monitor.ingest(openLine("192.168.31.99:1001", sid: "b"))
        clock.advance(60)
        monitor.ingest(openLine("192.168.31.99:1002", sid: "c"))
        XCTAssertEqual(naming.calls.count, 1, "a busy unnamed peer must not flood the resolver")

        clock.advance(300)   // past the 300 s retry delay
        monitor.ingest(openLine("192.168.31.99:1003", sid: "d"))
        await sleepUntil({ self.naming.calls.count == 2 },
                         message: "the retry after the delay never happened")
    }

    func testActiveMachinesSortAboveRetiredOnes() {
        let monitor = makeMonitor()
        monitor.ingest(openLine("192.168.31.42:1000", sid: "a"))
        monitor.ingest(closeLine("192.168.31.42:1000", sid: "a"))
        clock.advance(300)                                    // .42 goes quiet, past the active window
        monitor.ingest(openLine("192.168.31.77:2000", sid: "b"))
        monitor.publishNow()

        XCTAssertEqual(monitor.clients.map(\.ip), ["192.168.31.77", "192.168.31.42"])
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' \
  -only-testing:DevDeckTests/ProxyClientMonitorTests
```

Expected: compile failure — `cannot find 'ProxyClientMonitor' in scope`.

- [ ] **Step 4: Write the implementation**

Create `DevDeck/Proxy/ProxyClientMonitor.swift`:

```swift
import Foundation
import Observation

/// Who is using this machine's proxy share, folded out of the listener's own log stream.
///
/// The host side had no answer to "did anyone actually connect?" — the deck showed its listener was
/// up and announced, and nothing else. `gost` already reports every session open and close on
/// stderr, and `ProcessManager` already streams that; this type is the fold from those events to a
/// per-machine list.
///
/// Read-only observation on purpose: no byte counters, no destination hosts, no way to kick a peer.
///
/// Clock and resolver are injected (the probe pattern used across the proxy subsystem), so every
/// window below is tested without waiting for it.
@MainActor
@Observable
final class ProxyClientMonitor {

    /// One machine, identified by its address. Everything a view needs is precomputed here —
    /// views never touch the clock or the windows.
    struct Client: Identifiable, Equatable {
        let ip: String
        /// Resolved reverse name with `.local` stripped; nil while unresolved or unresolvable.
        var hostname: String?
        /// Sessions open right now. Zero is normal for a machine that is merely idle between requests.
        var liveSessions: Int
        let firstSeen: Date
        var lastSeen: Date
        /// Computed at publish time — see `activeWindow`.
        var isActive: Bool = false

        var id: String { ip }
        /// What the UI labels the row with. A bare IP is a worse name, never a wrong one.
        var displayName: String { hostname ?? ip }
    }

    /// Active machines first, then by last activity. Rebuilt at most once per `publishInterval`.
    private(set) var clients: [Client] = []
    /// What the popover counts. Derived, so it can never disagree with the list.
    var activeCount: Int { clients.filter(\.isActive).count }

    @ObservationIgnored private let naming: any ProxyClientNaming
    @ObservationIgnored private let now: () -> Date
    /// A machine with no open session still counts as connected for this long. Proxy sessions are
    /// short: without this the list would blink empty between two requests and the popover counter
    /// would flap.
    @ObservationIgnored private let activeWindow: TimeInterval
    /// How long a quiet machine stays listed (dimmed) before it is swept.
    @ObservationIgnored private let retention: TimeInterval
    /// How long a failed reverse lookup is remembered before another attempt. A peer can appear a
    /// moment before its mDNS record does, so failures are retried — just not per request.
    @ObservationIgnored private let nameRetryDelay: TimeInterval
    @ObservationIgnored private let publishInterval: Duration
    @ObservationIgnored private let sweepInterval: Duration

    /// Live sessions: sid → the machine that owns it.
    @ObservationIgnored private var sessions: [String: String] = [:]
    @ObservationIgnored private var entries: [String: Client] = [:]
    /// IP → the earliest time we may ask the resolver about it again. Also the in-flight guard.
    @ObservationIgnored private var nameRetryAfter: [String: Date] = [:]
    @ObservationIgnored private var publishTask: Task<Void, Never>?
    @ObservationIgnored private var sweepTask: Task<Void, Never>?

    /// This machine talking to its own listener — the exit-IP probe and a local `dp`. Not a peer.
    private static let ignoredIPs: Set<String> = ["127.0.0.1", "::1"]

    init(naming: any ProxyClientNaming = ReverseDNSClientNaming(),
         now: @escaping () -> Date = { Date() },
         activeWindow: TimeInterval = 120,
         retention: TimeInterval = 600,
         nameRetryDelay: TimeInterval = 300,
         publishInterval: Duration = .milliseconds(500),
         sweepInterval: Duration = .seconds(15)) {
        self.naming = naming
        self.now = now
        self.activeWindow = activeWindow
        self.retention = retention
        self.nameRetryDelay = nameRetryDelay
        self.publishInterval = publishInterval
        self.sweepInterval = sweepInterval
    }

    // MARK: - Input

    /// Fold one line of the listener's output into the list. Lines that are not session events —
    /// the overwhelming majority — cost one failed JSON parse and nothing else.
    func ingest(_ line: String) {
        guard let event = parseGostLogLine(line) else { return }
        let stamp = now()
        switch event {
        case .sessionOpened(let client, let sid):
            guard let ip = proxyClientIP(client), !Self.ignoredIPs.contains(ip) else { return }
            sessions[sid] = ip
            var entry = entries[ip] ?? Client(ip: ip, hostname: nil, liveSessions: 0,
                                              firstSeen: stamp, lastSeen: stamp)
            entry.liveSessions += 1
            entry.lastSeen = stamp
            entries[ip] = entry
            resolveNameIfNeeded(ip, at: stamp)
        case .sessionClosed(let sid):
            // An unknown sid belongs to a listener that is already gone — ignore it rather than
            // decrementing a counter that was reset under it.
            guard let ip = sessions.removeValue(forKey: sid), var entry = entries[ip] else { return }
            entry.liveSessions = max(0, entry.liveSessions - 1)
            entry.lastSeen = stamp
            entries[ip] = entry
        }
        schedulePublish()
    }

    // MARK: - Lifecycle

    /// The listener came up. Live sessions died with the previous process; who was here does not.
    func listenerDidStart() {
        sessions.removeAll()
        // Array(): the keys view is being mutated through while it is iterated.
        for ip in Array(entries.keys) { entries[ip]?.liveSessions = 0 }
        startSweep()
        publishNow()
    }

    /// The share was switched off — nobody is connected to something that is not running.
    func clear() {
        sweepTask?.cancel(); sweepTask = nil
        publishTask?.cancel(); publishTask = nil
        sessions.removeAll()
        entries.removeAll()
        nameRetryAfter.removeAll()
        publish()
    }

    // MARK: - Names

    private func resolveNameIfNeeded(_ ip: String, at stamp: Date) {
        guard entries[ip]?.hostname == nil else { return }
        if let retryAfter = nameRetryAfter[ip], stamp < retryAfter { return }
        // Set before the await: this doubles as the in-flight guard, so a burst of sessions from one
        // unnamed peer asks the resolver once, not once per request.
        nameRetryAfter[ip] = stamp.addingTimeInterval(nameRetryDelay)
        let naming = naming
        Task { @MainActor [weak self] in
            let name = await naming.hostname(for: ip)
            guard let self, let name, !name.isEmpty else { return }
            self.entries[ip]?.hostname = name
            self.schedulePublish()
        }
    }

    // MARK: - Publishing

    /// Rebuild `clients` immediately. Called by the sweep, by lifecycle changes, and by tests.
    func publishNow() {
        publishTask?.cancel()
        publishTask = nil
        publish()
    }

    /// A busy peer produces two events per request, so hundreds a second is ordinary — that must not
    /// become hundreds of SwiftUI invalidations.
    private func schedulePublish() {
        guard publishTask == nil else { return }
        let interval = publishInterval
        publishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            self.publishTask = nil
            self.publish()
        }
    }

    private func publish() {
        let stamp = now()
        let window = activeWindow
        clients = entries.values
            .map { entry -> Client in
                var client = entry
                client.isActive = entry.liveSessions > 0
                    || stamp.timeIntervalSince(entry.lastSeen) < window
                return client
            }
            .sorted { a, b in
                if a.isActive != b.isActive { return a.isActive }
                if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }
                return a.ip < b.ip
            }
    }

    // MARK: - Sweep

    /// Drop machines that have been quiet past the retention window, and republish: both the active
    /// flag and the "N min ago" label change with the passage of time alone, with no events at all.
    func sweepNow() {
        let stamp = now()
        let retention = retention
        entries = entries.filter {
            $0.value.liveSessions > 0 || stamp.timeIntervalSince($0.value.lastSeen) < retention
        }
        publishNow()
    }

    private func startSweep() {
        guard sweepTask == nil else { return }
        let interval = sweepInterval
        sweepTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                self.sweepNow()
            }
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' \
  -only-testing:DevDeckTests/ProxyClientMonitorTests
```

Expected: all 15 tests pass.

---

> **Amended during execution.** Review of Task 3 found two defects in the code this plan prescribed
> above, and the shipped code diverges from it on both points (commit `2bf61ba`):
> - `FakeProxyClientNaming` took an `NSLock` inside an `async` function, which warns today and is an
>   error in the Swift 6 language mode. The lock now lives in a synchronous helper. The fake also
>   grew `holdNextAnswer()` / `releaseHeldAnswer(_:)`, so a test can hold one lookup in flight.
> - `resolveNameIfNeeded`'s task was untracked and outlived `clear()`: with an IP reused between a
>   stop and a start, a stale answer could write a wrong hostname that no later lookup would correct.
>   The monitor now tracks resolve tasks per IP, cancels them in `clear()`, and carries a generation
>   counter checked after the await. Covered by `testAStaleResolveDoesNotNameTheEntryCreatedAfterAClear`.
>
> The monitor's public surface is unchanged, so the tasks below are unaffected.

---

### Task 4: Wiring — the output hook, `ProxyManager`, `AppDelegate`

**Files:**
- Modify: `DevDeck/Process/ProcessManager.swift` (the `// MARK: proxy routing` block near line 170, and the `.line` case of `apply` near line 1093)
- Modify: `DevDeck/Proxy/ProxyManager.swift` (init, `startAdvertising`, `stopShare`, new members)
- Modify: `DevDeck/AppDelegate.swift:39-41`
- Test: `DevDeckTests/ProxyClientWiringTests.swift`

**Interfaces:**
- Consumes: `ProxyClientMonitor` (Task 3).
- Produces: `ProcessManager.outputObserver: (UUID, String, OutputChannel) -> Void`;
  `ProxyManager.clientMonitor: ProxyClientMonitor`, `ProxyManager.ingestDaemonOutput(_ commandID: UUID, _ line: String)`,
  `ProxyManager.proxyClients: [ProxyClientMonitor.Client]`, `ProxyManager.connectedClientCount: Int`.
  Tasks 5 and 6 read the last two.

- [ ] **Step 1: Write the failing tests**

Create `DevDeckTests/ProxyClientWiringTests.swift`:

```swift
import XCTest
@testable import DevDeck

/// The path from a daemon's stdout/stderr to the connected-machines list: `ProcessManager` reports
/// every line through a generic hook, `AppDelegate` points that hook at `ProxyManager`, and
/// `ProxyManager` keeps only the proxy listener's own output.
@MainActor
final class ProxyClientWiringTests: XCTestCase {

    private func openLine(_ client: String, sid: String) -> String {
        """
        {"client":"\(client)","kind":"handler","level":"info","local":"192.168.31.5:9999",\
        "msg":"\(client) <> 192.168.31.5:9999","service":"devdeck-proxy","sid":"\(sid)"}
        """
    }

    func testProcessManagerReportsEveryOutputLine() async {
        let runner = FakeCommandRunner()
        let manager = ProcessManager(runner: runner)
        let command = Command(name: "echo", command: "echo hi")
        runner.eagerScripts[command.id] = [
            .started(pid: 1),
            .line("hello", stream: .stdout),
            .line("trouble", stream: .stderr),
            .terminated(exitCode: 0),
        ]

        var seen: [(UUID, String, OutputChannel)] = []
        manager.outputObserver = { seen.append(($0, $1, $2)) }
        manager.run(command)

        await sleepUntil({ seen.count == 2 }, message: "the output hook never fired")
        XCTAssertEqual(seen.map(\.1), ["hello", "trouble"])
        XCTAssertEqual(seen.map(\.0), [command.id, command.id])
        XCTAssertEqual(seen.map(\.2), [.stdout, .stderr])
    }

    func testOnlyTheListenersOwnOutputCounts() {
        let monitor = ProxyClientMonitor(naming: FakeProxyClientNaming(),
                                         publishInterval: .seconds(3600),
                                         sweepInterval: .seconds(3600))
        let proxy = ProxyManager(discovering: FakeProxyDiscovering(),
                                 advertiser: FakeProxyAdvertising(),
                                 credentials: FakeProxyCredentialStore(),
                                 clientMonitor: monitor)

        proxy.ingestDaemonOutput(ProxyShare.daemonID, openLine("192.168.31.42:1000", sid: "a"))
        proxy.ingestDaemonOutput(UUID(), openLine("192.168.31.77:2000", sid: "b"))
        monitor.publishNow()

        XCTAssertEqual(proxy.proxyClients.map(\.ip), ["192.168.31.42"],
                       "another daemon printing gost-shaped JSON must not invent a client")
        XCTAssertEqual(proxy.connectedClientCount, 1)
    }

    func testStoppingTheShareEmptiesTheList() {
        let monitor = ProxyClientMonitor(naming: FakeProxyClientNaming(),
                                         publishInterval: .seconds(3600),
                                         sweepInterval: .seconds(3600))
        let proxy = ProxyManager(discovering: FakeProxyDiscovering(),
                                 advertiser: FakeProxyAdvertising(),
                                 credentials: FakeProxyCredentialStore(),
                                 clientMonitor: monitor)

        proxy.ingestDaemonOutput(ProxyShare.daemonID, openLine("192.168.31.42:1000", sid: "a"))
        monitor.publishNow()
        XCTAssertEqual(proxy.connectedClientCount, 1)

        proxy.stopShare()
        XCTAssertTrue(proxy.proxyClients.isEmpty)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' \
  -only-testing:DevDeckTests/ProxyClientWiringTests
```

Expected: compile failure — `value of type 'ProcessManager' has no member 'outputObserver'`.

- [ ] **Step 3: Add the hook to `ProcessManager`**

In `DevDeck/Process/ProcessManager.swift`, under `// MARK: proxy routing`, directly after the
`proxyRouting` declaration:

```swift
    /// Every output line of every run, as it arrives. Injected by `AppDelegate` (a closure, not a
    /// type dependency — `ProcessManager` stays unaware of `ProxyManager`), which points it at the
    /// connected-clients monitor. The filtering for the proxy listener happens on the other side:
    /// the hook is generic, and one closure call per log line costs nothing.
    @ObservationIgnored var outputObserver: (UUID, String, OutputChannel) -> Void = { _, _, _ in }
```

In the same file, in `apply`, extend the `.line` case:

```swift
        case .line(let text, let stream):
            appendLog(commandID, text, stream)
            outputObserver(commandID, text, stream)
```

- [ ] **Step 4: Wire `ProxyManager`**

In `DevDeck/Proxy/ProxyManager.swift`:

Add the stored property next to the other injected dependencies:

```swift
    /// Who is using our share, folded out of the listener's own output.
    @ObservationIgnored let clientMonitor: ProxyClientMonitor
```

Add the init parameter (last, after `shareConfigFile`) and its assignment:

```swift
        clientMonitor: ProxyClientMonitor = ProxyClientMonitor()
```
```swift
        self.clientMonitor = clientMonitor
```

Add the two read-only members for the views, next to `visibleProxies`:

```swift
    /// Machines that have used this share recently (host side).
    var proxyClients: [ProxyClientMonitor.Client] { clientMonitor.clients }
    /// How many of them count as connected right now — what the popover shows.
    var connectedClientCount: Int { clientMonitor.activeCount }

    /// Feed the listener's own output to the connected-clients monitor, and nothing else's: any
    /// other daemon may legitimately print JSON that looks like a gost session.
    func ingestDaemonOutput(_ commandID: UUID, _ line: String) {
        guard commandID == ProxyShare.daemonID else { return }
        clientMonitor.ingest(line)
    }
```

In `startAdvertising()`, immediately after `isAdvertising = true`:

```swift
        // Guarded by `isAdvertising`, so this runs exactly once per bring-up of the listener —
        // including a watchdog restart, whose sessions all died with the previous process.
        clientMonitor.listenerDidStart()
```

In `stopShare()`, after `stopAdvertising()`:

```swift
        clientMonitor.clear()
```

Note the asymmetry, and leave it: a listener that merely *died* keeps its list (the watchdog is
about to bring it back), while an explicit stop empties it.

- [ ] **Step 5: Wire `AppDelegate`**

In `DevDeck/AppDelegate.swift`, directly after the `manager.proxyRouting = { … }` assignment:

```swift
        // The listener's own log lines are where "who is connected" comes from.
        manager.outputObserver = { [weak proxyManager] commandID, line, _ in
            proxyManager?.ingestDaemonOutput(commandID, line)
        }
```

- [ ] **Step 6: Run the tests to verify they pass**

```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' \
  -only-testing:DevDeckTests/ProxyClientWiringTests
```

Expected: all 3 tests pass.

- [ ] **Step 7: Run the whole suite — the hook touches every run**

```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'
```

Expected: no regressions, in particular in `ProcessManager*Tests` and `ProxyManager*Tests`.

---

> **Amended during execution.** Two changes to the code prescribed above (commits `6a465a7`, `6152aac`):
> - `ProxyClientMonitor.init` is `nonisolated`, or the `clientMonitor: ProxyClientMonitor = ProxyClientMonitor()`
>   default argument does not compile (a `@MainActor` init called from a nonisolated default-argument
>   context). Matches the house pattern — `LiveAppController`, `LiveNotifier`, `DaemonReaper`.
> - The tests in `ProxyClientWiringTests` inject `shareConfigFile: FakePrivateFile()`. Without it,
>   `stopShare()` unlinks the developer's real `~/Library/Application Support/DevDeck/gost.json` —
>   which it did, on this machine, before the fix. `ProxyManagerShareTests` already established the
>   convention; every `PrivateFileWriting` dependency of `ProxyManager` should be injected in tests.

---

### Task 5: The list on the Proxy page

**Files:**
- Modify: `DevDeck/Localization/L10n.swift` (the proxy block, near line 340)
- Modify: `DevDeck/MainWindow/ProxyShareEditorView.swift`

**Interfaces:**
- Consumes: `ProxyManager.proxyClients`, `ProxyClientMonitor.Client` (Task 4).
- Produces: `L10n.proxyConnectedSection`, `L10n.proxyNoConnections`, `L10n.proxyClientActive`,
  `L10n.proxySessions(_:)`, `L10n.proxyLastSeen(_:)`, `L10n.proxyConnectedCount(_:)`.
  Task 6 uses `proxyConnectedCount`.

- [ ] **Step 1: Add the strings**

In `DevDeck/Localization/L10n.swift`, at the end of the proxy block (after `proxyNoneFound`):

```swift
    // MARK: - Proxy: connected machines (host side)

    static var proxyConnectedSection: String { t("Connected machines", "Подключённые машины") }
    static var proxyNoConnections: String {
        t("Nobody has connected yet", "Пока никто не подключался")
    }
    static var proxyClientActive: String { t("active", "активна") }
    /// Written as "sessions: N" in both languages — it sidesteps English and Russian number
    /// agreement, so no plural helper is needed anywhere in the catalog.
    static func proxySessions(_ count: Int) -> String {
        t("sessions: \(count)", "сессий: \(count)")
    }
    static func proxyLastSeen(_ minutes: Int) -> String {
        minutes < 1 ? t("just now", "только что") : t("\(minutes) min ago", "\(minutes) мин назад")
    }
    /// Same trick: "connected N", not "N machines".
    static func proxyConnectedCount(_ count: Int) -> String {
        t("connected \(count)", "подключено \(count)")
    }
```

- [ ] **Step 2: Render the section**

In `DevDeck/MainWindow/ProxyShareEditorView.swift`, add `connectedSection` to the form, between
`shareSection` and `discoverySection`:

```swift
        Form {
            shareSection
            connectedSection
            discoverySection
            terminalHelperSection
        }
```

Add the section itself, after the `shareStatus` / `shareHasChanges` / `saveShare` block that closes
the host side:

```swift
    // MARK: - Connected machines (host side)

    /// Only meaningful while this Mac is sharing — a machine that only consumes has no clients.
    @ViewBuilder
    private var connectedSection: some View {
        if store.config.settings.proxyShareEnabled {
            Section(L10n.proxyConnectedSection) {
                if proxy.proxyClients.isEmpty {
                    Text(L10n.proxyNoConnections).font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(proxy.proxyClients) { client in
                        connectedRow(client)
                    }
                }
            }
        }
    }

    private func connectedRow(_ client: ProxyClientMonitor.Client) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "laptopcomputer").foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(client.displayName)
                // Only when it adds something: an unnamed machine already shows its address above.
                if client.hostname != nil {
                    Text(client.ip)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            connectedStatus(client)
        }
    }

    @ViewBuilder
    private func connectedStatus(_ client: ProxyClientMonitor.Client) -> some View {
        HStack(spacing: 5) {
            if client.isActive {
                Circle().fill(.green).frame(width: 7, height: 7)
                // Zero live sessions is normal for a machine idling between requests — say "active"
                // rather than "sessions: 0", which reads like a bug.
                Text(client.liveSessions > 0 ? L10n.proxySessions(client.liveSessions)
                                             : L10n.proxyClientActive)
            } else {
                Text(L10n.proxyLastSeen(minutesSince(client.lastSeen)))
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    /// Whole minutes since `date`. Evaluated during `body`, which is fine: the monitor republishes
    /// on its sweep, so the label refreshes without a timer of its own here.
    private func minutesSince(_ date: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(date) / 60))
    }
```

- [ ] **Step 3: Build and run the whole suite**

```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'
```

Expected: builds, all tests pass (this task adds no tests — it is view code, and the project has no
view test target).

- [ ] **Step 4: Verify by hand against a real listener**

1. Launch the app, turn **Share the proxy on the local network** on, confirm the listener is running.
2. Find this Mac's LAN address: `ipconfig getifaddr en0`.
3. Drive traffic through the share **using that address, not `127.0.0.1`** (loopback is filtered on
   purpose, and a connection to your own en0 address is reported by gost with the en0 address as its
   client, so it shows up as a normal machine):
   ```
   curl -s -x http://$(ipconfig getifaddr en0):9999 https://api.ipify.org
   ```
4. Open the main window → **Proxy**. Within about a second a row appears: this Mac's name (or its
   IP), a green dot, and `sessions: …` or `active`.
5. Wait ~2 minutes without traffic: the green dot goes away and the row reads `N min ago`.

---

### Task 6: The counter in the popover

**Files:**
- Modify: `DevDeck/MenuBar/ProxySectionView.swift` (the `shareRows` announcement line, near line 61)

**Interfaces:**
- Consumes: `ProxyManager.connectedClientCount` (Task 4), `L10n.proxyConnectedCount(_:)` (Task 5).
- Produces: nothing.

- [ ] **Step 1: Extend the announcement line**

In `DevDeck/MenuBar/ProxySectionView.swift`, inside `shareRows`, in the `else if proxy.isAdvertising`
branch, after the `exitIP` block and before `Spacer()`:

```swift
                // The popover stays a control deck: one segment on a line that already exists,
                // never a list. The full roster lives on the Proxy page.
                if proxy.connectedClientCount > 0 {
                    Text("·")
                    Text(L10n.proxyConnectedCount(proxy.connectedClientCount))
                }
```

- [ ] **Step 2: Build and run the whole suite**

```
DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test \
  -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'
```

Expected: builds, all tests pass.

- [ ] **Step 3: Verify by hand**

1. With the share running, drive traffic exactly as in Task 5 Step 4.
2. Open the popover: the proxy row's second line reads
   `Announced on the network · <exit IP> · connected 1` (`подключено 1` in Russian).
3. Leave it idle for over two minutes and reopen: the `connected …` segment disappears while the
   row on the Proxy page stays, dimmed.
4. Switch the app language in Settings and confirm both the popover segment and the Proxy page
   section follow it.

---

## Notes for the implementer

- **Where the data comes from.** `gost` writes one JSON object per session event to stderr;
  `ProcessManager` already streams those lines into `logs[ProxyShare.daemonID]`. Nothing new is
  launched and no port is opened. If gost ever changes its format, `parseGostLogLine` returns nil for
  every line and the feature degrades to "nobody has connected yet" — never to a wrong list.
- **An adopted listener produces nothing.** An orphaned `gost` has no pipe, so no lines arrive. This
  is not a regression: adoption of this particular daemon has never worked, for the reason recorded
  in `ProxyShare.toCommand` — a surviving `gost` surfaces as an occupied port instead.
- **Do not add byte counters or destination hosts.** Both are right there in the log lines and both
  are deliberately out of scope; the second is somebody else's browsing history.
