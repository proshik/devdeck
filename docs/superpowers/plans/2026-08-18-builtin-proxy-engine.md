# Built-in Proxy Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An in-process HTTP proxy listener (Network.framework) selectable per share as the engine — `builtIn` (new default) or `gost` — with everything downstream (supervision, announcement, client monitor, routing) unchanged.

**Architecture:** The built-in listener is a fourth `CommandRunner` behind `RoutingCommandRunner`, started from a marker command (`devdeck:proxy-listen -C <configPath>`); the share stays a synthetic daemon. Both engines start from the same generated 0600 `gost.json`; the built-in engine reads `addr` + `auth` back out of it and logs gost-shaped session lines so `ProxyClientMonitor` works untouched.

**Tech Stack:** Swift, Network.framework (`NWListener`/`NWConnection`), XCTest. Zero third-party dependencies.

**Spec:** `docs/superpowers/specs/2026-08-18-builtin-proxy-engine-design.md`

## Global Constraints

- Build/test command prefix: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild …` (xcode-select points at CommandLineTools).
- Full test run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS'`. For a single class add `-only-testing:DevDeckTests/<ClassName>`.
- The Xcode project uses file-system-synchronized groups: creating a `.swift` file under `DevDeck/` or `DevDeckTests/` is enough — never edit `project.pbxproj`.
- Zero third-party dependencies; code comments in English, UI strings via `L10n.t("EN", "RU")`.
- Do NOT bump `Config.currentSchemaVersion` — `engine` decodes with a default.
- Commit messages: conventional (`feat(proxy): …`), no `Co-Authored-By` trailers.
- `RunnerOutput` stream invariant (must hold for the new runner): exactly one `.started` → 0..n `.line` → exactly one `.terminated` → `finish()`; `stop()` idempotent, its effect visible only as the subsequent `.terminated`.

---

### Task 1: `ProxyEngine` on the model + the marker command

**Files:**
- Modify: `DevDeck/Models/ProxyShare.swift`
- Test: `DevDeckTests/ProxyShareMappingTests.swift`

**Interfaces:**
- Consumes: existing `ProxyShare`, `shellQuote(_:)` (`DevDeck/Support/ShellQuoting.swift`), `L10n.t`.
- Produces (later tasks rely on these exact names):
  - `enum ProxyEngine: String, Codable, CaseIterable { case builtIn, gost }`
  - `ProxyShare.engine: ProxyEngine` (decoding default `.builtIn`)
  - `ProxyShare.builtInCommandPrefix == "devdeck:proxy-listen -C "` (static let)
  - `ProxyShare.toCommand(gostPath: String?, configPath: String) -> Command?` — nil only for `.gost` with `gostPath == nil`; the `.builtIn` command string is the prefix + **raw unquoted** path (no shell ever parses it)
  - `L10n.proxyShareDaemonNameBuiltIn`

- [ ] **Step 1: Write the failing tests** — append to `ProxyShareMappingTests`:

```swift
// MARK: - Engine

func testEngineDefaultsToBuiltInWhenAbsent() throws {
    let json = #"{"port": 9999}"#
    let share = try JSONDecoder().decode(ProxyShare.self, from: Data(json.utf8))
    XCTAssertEqual(share.engine, .builtIn)
}

func testEngineDecodesAndSurvivesRoundTrip() throws {
    var share = ProxyShare()
    share.engine = .gost
    let data = try JSONEncoder().encode(share)
    let back = try JSONDecoder().decode(ProxyShare.self, from: data)
    XCTAssertEqual(back.engine, .gost)
}

func testUnknownEngineStringFallsBackToBuiltIn() throws {
    let json = #"{"engine": "socks-magic"}"#
    let share = try JSONDecoder().decode(ProxyShare.self, from: Data(json.utf8))
    XCTAssertEqual(share.engine, .builtIn)
}

func testBuiltInCommandUsesMarkerAndRawPath() throws {
    var share = ProxyShare(port: 9999)
    share.engine = .builtIn
    let command = try XCTUnwrap(share.toCommand(gostPath: nil, configPath: "/tmp/dir with space/gost.json"))
    XCTAssertEqual(command.command, "devdeck:proxy-listen -C /tmp/dir with space/gost.json")
    XCTAssertEqual(command.id, ProxyShare.daemonID)
    XCTAssertTrue(command.isDaemon)
    XCTAssertTrue(command.watchdogEnabled)
    XCTAssertEqual(command.port, 9999)
}

func testGostCommandNilWithoutBinary() {
    var share = ProxyShare()
    share.engine = .gost
    XCTAssertNil(share.toCommand(gostPath: nil, configPath: "/tmp/gost.json"))
}

func testBuiltInCommandIgnoresMissingGost() {
    var share = ProxyShare()
    share.engine = .builtIn
    XCTAssertNotNil(share.toCommand(gostPath: nil, configPath: "/tmp/gost.json"))
}
```

Also update the two existing `toCommand` call sites in this test file: the return is now optional — wrap with `try XCTUnwrap(...)` and set `share.engine = .gost` in the fixtures that assert the gost command line (their assertions stay byte-identical).

- [ ] **Step 2: Run to verify failure**

Run: `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' -only-testing:DevDeckTests/ProxyShareMappingTests 2>&1 | tail -20`
Expected: compile error — `engine` / `builtInCommandPrefix` not defined.

- [ ] **Step 3: Implement** in `ProxyShare.swift`:

```swift
/// Which implementation serves the share. `builtIn` is the default: an in-process HTTP
/// CONNECT/absolute-form listener with no external dependency. `gost` remains for peers
/// that need SOCKS.
enum ProxyEngine: String, Codable, CaseIterable {
    case builtIn, gost
}
```

In `ProxyShare`: add `var engine: ProxyEngine`, an `engine: ProxyEngine = .builtIn` init parameter (last, defaulted — existing call sites keep compiling), `case engine` in `CodingKeys`, and in `init(from:)`:

```swift
// Resilient like every other key — and an unknown STRING (a config written by a newer
// version) falls back rather than failing the whole config.
let rawEngine = try c.decodeIfPresent(String.self, forKey: .engine)
engine = rawEngine.flatMap(ProxyEngine.init(rawValue:)) ?? .builtIn
```

Add the marker and rework `toCommand`:

```swift
/// Marker command for the built-in engine. `RoutingCommandRunner` dispatches on this prefix;
/// no shell ever parses the string, so the path after `-C ` is verbatim, not quoted.
static let builtInCommandPrefix = "devdeck:proxy-listen -C "

/// The synthetic daemon `Command` fed to `ProcessManager`, per engine.
/// nil only for `.gost` without an installed binary (→ the UI warns, nothing starts).
func toCommand(gostPath: String?, configPath: String) -> Command? {
    let commandLine: String
    switch engine {
    case .gost:
        guard let gostPath else { return nil }
        commandLine = "\(shellQuote(gostPath)) -C \(shellQuote(configPath))"
    case .builtIn:
        commandLine = Self.builtInCommandPrefix + configPath
    }
    return Command(
        id: Self.daemonID,
        name: engine == .builtIn ? L10n.proxyShareDaemonNameBuiltIn : L10n.proxyShareDaemonName,
        command: commandLine,
        isDaemon: true,
        watchdogEnabled: true,
        port: port
    )
}
```

Keep the existing doc comment about argv/adoption on the gost branch. In `L10n.swift`, next to `proxyShareDaemonName`:

```swift
static var proxyShareDaemonNameBuiltIn: String { t("Proxy (built-in)", "Прокси (встроенный)") }
```

Fix the one production call site (`ProxyManager.shareCommand()`) minimally so the project compiles — the full `ProxyManager` behavior lands in Task 5:

```swift
func shareCommand() -> Command? {
    share.toCommand(gostPath: gostPath(share), configPath: shareConfigFile.url.path)
}
```

- [ ] **Step 4: Run to verify pass** — same command as Step 2, plus `-only-testing:DevDeckTests/ProxyManagerShareTests` (its fixtures inject `gostPath`; if any construct `ProxyShare` expecting the gost engine, set `engine: .gost` there). Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Models/ProxyShare.swift DevDeck/Localization/L10n.swift DevDeckTests/ProxyShareMappingTests.swift DevDeckTests/ProxyManagerShareTests.swift
git commit -m "feat(proxy): ProxyEngine model with builtIn default and marker command"
```

---

### Task 2: Config read-back — the built-in engine's slice of `gost.json`

**Files:**
- Modify: `DevDeck/Models/ProxyShare.swift` (make `GostConfig`/`GostService`/`GostHandler`/`GostAuth`/`GostListener` `Codable` instead of `Encodable`)
- Create: `DevDeck/Proxy/BuiltInProxyConfig.swift`
- Test: `DevDeckTests/BuiltInProxyConfigTests.swift`

**Interfaces:**
- Produces: `func parseBuiltInProxyConfig(_ data: Data) -> (port: Int, auth: GostAuth?)?` — pure; nil on malformed JSON, missing service, or unparsable `addr`.

- [ ] **Step 1: Write the failing tests** (`BuiltInProxyConfigTests.swift`):

```swift
import XCTest
@testable import DevDeck

/// The writer (`gostConfigJSON`) and the reader are asserted against each other: both engines
/// start from the same generated file, so a drift between them would break only the built-in one.
final class BuiltInProxyConfigTests: XCTestCase {

    func testRoundTripWithAuth() throws {
        let share = ProxyShare(port: 9876, authEnabled: true, username: "dev")
        let json = try XCTUnwrap(share.gostConfigJSON(password: "s3cr:et"))
        let parsed = try XCTUnwrap(parseBuiltInProxyConfig(Data(json.utf8)))
        XCTAssertEqual(parsed.port, 9876)
        XCTAssertEqual(parsed.auth, GostAuth(username: "dev", password: "s3cr:et"))
    }

    func testRoundTripOpenProxy() throws {
        let share = ProxyShare(port: 9999, authEnabled: false)
        let json = try XCTUnwrap(share.gostConfigJSON(password: nil))
        let parsed = try XCTUnwrap(parseBuiltInProxyConfig(Data(json.utf8)))
        XCTAssertEqual(parsed.port, 9999)
        XCTAssertNil(parsed.auth)
    }

    func testMalformedInputsReturnNil() {
        XCTAssertNil(parseBuiltInProxyConfig(Data("not json".utf8)))
        XCTAssertNil(parseBuiltInProxyConfig(Data(#"{"services": []}"#.utf8)))
        XCTAssertNil(parseBuiltInProxyConfig(Data(
            #"{"services":[{"name":"x","addr":"nonsense","handler":{"type":"auto"},"listener":{"type":"tcp"}}]}"#.utf8)))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `-only-testing:DevDeckTests/BuiltInProxyConfigTests`. Expected: compile error (`parseBuiltInProxyConfig` undefined).

- [ ] **Step 3: Implement.** In `ProxyShare.swift` change the five `Encodable` conformances to `Codable` (add `let auth: GostAuth?` decoding for free — synthesized). New `BuiltInProxyConfig.swift`:

```swift
import Foundation

/// The slice of the generated `gost.json` the built-in engine starts from: the first service's
/// port and optional auth. Pure — nil on anything unexpected, and the runner then fails the run
/// loudly (same shape as `gost -C` on a broken file).
func parseBuiltInProxyConfig(_ data: Data) -> (port: Int, auth: GostAuth?)? {
    guard let config = try? JSONDecoder().decode(GostConfig.self, from: data),
          let service = config.services.first else { return nil }
    // addr is ":PORT" as generated; tolerate a host prefix by taking the last colon's suffix.
    guard let colon = service.addr.lastIndex(of: ":"),
          let port = Int(service.addr[service.addr.index(after: colon)...]),
          port > 0 else { return nil }
    return (port, service.handler.auth)
}
```

- [ ] **Step 4: Run to verify pass** — same filter, plus `-only-testing:DevDeckTests/ProxyShareMappingTests` (the config-JSON assertions must be unaffected). Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Models/ProxyShare.swift DevDeck/Proxy/BuiltInProxyConfig.swift DevDeckTests/BuiltInProxyConfigTests.swift
git commit -m "feat(proxy): read the generated share config back for the built-in engine"
```

---

### Task 3: `HTTPProxyParser` — the pure HTTP half

**Files:**
- Create: `DevDeck/Proxy/HTTPProxyParser.swift`
- Test: `DevDeckTests/HTTPProxyParserTests.swift`

**Interfaces:**
- Produces (exact names, used by Task 4):

```swift
struct HTTPHeader: Equatable { let name: String; let value: String }
struct HTTPRequestHead: Equatable {
    let method: String; let target: String; let version: String; let headers: [HTTPHeader]
    func firstValue(of name: String) -> String?          // case-insensitive
}
let httpHeadTerminator: Data                              // "\r\n\r\n"
let httpMaxHeadBytes: Int                                 // 65_536
func parseHTTPRequestHead(_ head: Data) -> HTTPRequestHead?   // input EXCLUDES the terminator
enum ProxyRequestKind: Equatable {
    case connect(host: String, port: Int)
    case absoluteForm(host: String, port: Int, rewrittenHead: Data)  // rewritten head INCLUDES terminator
    case bad
}
func classifyProxyRequest(_ head: HTTPRequestHead) -> ProxyRequestKind
func proxyAuthorized(_ head: HTTPRequestHead, username: String, password: String) -> Bool
func proxyResponse200() -> Data   // "HTTP/1.1 200 Connection Established\r\n\r\n"
func proxyResponse407() -> Data   // + "Proxy-Authenticate: Basic realm=\"DevDeck\"" header
func proxyResponse400() -> Data
func proxyResponse502() -> Data
func builtInSessionLine(open: Bool, client: String, sid: String, port: Int) -> String
```

- [ ] **Step 1: Write the failing tests** (`HTTPProxyParserTests.swift`):

```swift
import XCTest
@testable import DevDeck

final class HTTPProxyParserTests: XCTestCase {

    private func head(_ s: String) -> HTTPRequestHead {
        parseHTTPRequestHead(Data(s.utf8))!
    }

    // MARK: - Head parsing

    func testParsesConnectHead() {
        let h = head("CONNECT api.ipify.org:443 HTTP/1.1\r\nHost: api.ipify.org:443\r\nUser-Agent: curl/8.6")
        XCTAssertEqual(h.method, "CONNECT")
        XCTAssertEqual(h.target, "api.ipify.org:443")
        XCTAssertEqual(h.version, "HTTP/1.1")
        XCTAssertEqual(h.firstValue(of: "user-agent"), "curl/8.6")
    }

    func testRejectsGarbage() {
        XCTAssertNil(parseHTTPRequestHead(Data("\u{16}\u{03}tls-client-hello".utf8)))  // TLS byte soup
        XCTAssertNil(parseHTTPRequestHead(Data("ONLYONEWORD\r\n".utf8)))
        XCTAssertNil(parseHTTPRequestHead(Data()))
    }

    // MARK: - Classification

    func testClassifiesConnect() {
        XCTAssertEqual(classifyProxyRequest(head("CONNECT example.com:443 HTTP/1.1")),
                       .connect(host: "example.com", port: 443))
        XCTAssertEqual(classifyProxyRequest(head("CONNECT [::1]:8443 HTTP/1.1")),
                       .connect(host: "::1", port: 8443))
        XCTAssertEqual(classifyProxyRequest(head("CONNECT noport HTTP/1.1")), .bad)
    }

    func testClassifiesAbsoluteFormAndRewrites() throws {
        let kind = classifyProxyRequest(head(
            "GET http://example.com/a/b?q=1 HTTP/1.1\r\nHost: example.com\r\nProxy-Connection: keep-alive\r\nProxy-Authorization: Basic Zm9v\r\nAccept: */*"))
        guard case .absoluteForm(let host, let port, let rewritten) = kind else {
            return XCTFail("expected absoluteForm, got \(kind)")
        }
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(port, 80)
        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /a/b?q=1 HTTP/1.1\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"))
        XCTAssertTrue(text.contains("Host: example.com\r\n"))
        XCTAssertTrue(text.contains("Accept: */*\r\n"))
        XCTAssertFalse(text.lowercased().contains("proxy-"), "hop-by-hop proxy headers must not reach the origin")
    }

    func testAbsoluteFormNonDefaultPortAndOriginFormRejected() {
        XCTAssertEqual(classifyProxyRequest(head("GET http://example.com:8080/x HTTP/1.1\r\nHost: h")).hostPort,
                       "example.com:8080")
        XCTAssertEqual(classifyProxyRequest(head("GET /just/a/path HTTP/1.1\r\nHost: h")), .bad)
        XCTAssertEqual(classifyProxyRequest(head("GET https://example.com/ HTTP/1.1\r\nHost: h")), .bad,
                       "https:// absolute-form through a plain proxy is not a thing — clients use CONNECT")
    }

    // MARK: - Auth

    func testAuthAcceptsMatchingBasicCredentials() {
        let b64 = Data("dev:s3cr:et".utf8).base64EncodedString()  // password containing ':'
        let h = head("CONNECT x:443 HTTP/1.1\r\nProxy-Authorization: Basic \(b64)")
        XCTAssertTrue(proxyAuthorized(h, username: "dev", password: "s3cr:et"))
    }

    func testAuthRejectsMissingWrongSchemeAndWrongCredentials() {
        XCTAssertFalse(proxyAuthorized(head("CONNECT x:443 HTTP/1.1"), username: "dev", password: "p"))
        XCTAssertFalse(proxyAuthorized(head("CONNECT x:443 HTTP/1.1\r\nProxy-Authorization: Bearer zzz"),
                                       username: "dev", password: "p"))
        let wrong = Data("dev:nope".utf8).base64EncodedString()
        XCTAssertFalse(proxyAuthorized(head("CONNECT x:443 HTTP/1.1\r\nProxy-Authorization: Basic \(wrong)"),
                                       username: "dev", password: "p"))
    }

    // MARK: - Responses

    func testResponses() {
        XCTAssertEqual(String(decoding: proxyResponse200(), as: UTF8.self),
                       "HTTP/1.1 200 Connection Established\r\n\r\n")
        let s407 = String(decoding: proxyResponse407(), as: UTF8.self)
        XCTAssertTrue(s407.hasPrefix("HTTP/1.1 407 "))
        XCTAssertTrue(s407.contains("Proxy-Authenticate: Basic realm=\"DevDeck\"\r\n"))
        XCTAssertTrue(String(decoding: proxyResponse400(), as: UTF8.self).hasPrefix("HTTP/1.1 400 "))
        XCTAssertTrue(String(decoding: proxyResponse502(), as: UTF8.self).hasPrefix("HTTP/1.1 502 "))
    }

    // MARK: - Session lines (must round-trip through the gost parser)

    func testSessionLinesParseBackThroughGostParser() {
        let open = builtInSessionLine(open: true, client: "192.168.31.42:55904", sid: "abc123", port: 9999)
        let close = builtInSessionLine(open: false, client: "192.168.31.42:55904", sid: "abc123", port: 9999)
        XCTAssertEqual(parseGostLogLine(open), .sessionOpened(client: "192.168.31.42:55904", sid: "abc123"))
        XCTAssertEqual(parseGostLogLine(close), .sessionClosed(sid: "abc123"))
    }
}

private extension ProxyRequestKind {
    /// Compact assertion helper: "host:port" for either routed kind, nil for .bad.
    var hostPort: String? {
        switch self {
        case .connect(let h, let p), .absoluteForm(let h, let p, _): return "\(h):\(p)"
        case .bad: return nil
        }
    }
}
```

- [ ] **Step 2: Run to verify failure** — `-only-testing:DevDeckTests/HTTPProxyParserTests`. Expected: compile error.

- [ ] **Step 3: Implement** `HTTPProxyParser.swift` — pure, no I/O:

```swift
import Foundation

/// The pure half of the built-in proxy: request-head parsing, request classification,
/// Basic-auth verification, canned responses, and gost-shaped session lines.
/// No sockets here — everything is unit-tested byte-in/byte-out.

struct HTTPHeader: Equatable {
    let name: String
    let value: String
}

struct HTTPRequestHead: Equatable {
    let method: String
    let target: String
    let version: String
    let headers: [HTTPHeader]

    func firstValue(of name: String) -> String? {
        headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// End of an HTTP request head on the wire.
let httpHeadTerminator = Data("\r\n\r\n".utf8)
/// Cap for an accumulated head — over this the connection is answered 400 and closed.
let httpMaxHeadBytes = 65_536

/// Parse a request head (bytes BEFORE the terminator). nil for anything that is not
/// `METHOD SP TARGET SP HTTP/x.y` followed by `Name: value` lines — TLS bytes, SOCKS
/// greetings and garbage all fail closed here.
func parseHTTPRequestHead(_ head: Data) -> HTTPRequestHead? {
    guard let text = String(data: head, encoding: .utf8) else { return nil }
    var lines = text.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return nil }
    lines.removeFirst()
    let parts = requestLine.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, !parts[0].isEmpty, !parts[1].isEmpty, parts[2].hasPrefix("HTTP/") else { return nil }
    var headers: [HTTPHeader] = []
    for line in lines where !line.isEmpty {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        headers.append(HTTPHeader(name: name, value: value))
    }
    return HTTPRequestHead(method: parts[0], target: parts[1], version: parts[2], headers: headers)
}

enum ProxyRequestKind: Equatable {
    case connect(host: String, port: Int)
    /// `rewrittenHead` is origin-form with `Proxy-*` headers dropped, terminator included —
    /// ready to send to the origin verbatim, followed by whatever came after the client's head.
    case absoluteForm(host: String, port: Int, rewrittenHead: Data)
    case bad
}

func classifyProxyRequest(_ head: HTTPRequestHead) -> ProxyRequestKind {
    if head.method == "CONNECT" {
        // "host:port", IPv6 bracketed — same split as proxyClientIP.
        guard let colon = head.target.lastIndex(of: ":"),
              let port = Int(head.target[head.target.index(after: colon)...]), port > 0 else { return .bad }
        var host = String(head.target[head.target.startIndex..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? .bad : .connect(host: host, port: port)
    }
    // Absolute-form plain HTTP: `GET http://host[:port]/path HTTP/1.1`. https:// never arrives
    // here (clients CONNECT for TLS), and origin-form has no destination — both are .bad.
    guard let url = URL(string: head.target), url.scheme == "http", let host = url.host, !host.isEmpty
    else { return .bad }
    let port = url.port ?? 80
    var path = url.path.isEmpty ? "/" : url.path
    if let query = url.query { path += "?\(query)" }
    var rewritten = "\(head.method) \(path) \(head.version)\r\n"
    for header in head.headers where !header.name.lowercased().hasPrefix("proxy-") {
        rewritten += "\(header.name): \(header.value)\r\n"
    }
    rewritten += "\r\n"
    return .absoluteForm(host: host, port: port, rewrittenHead: Data(rewritten.utf8))
}

/// `Proxy-Authorization: Basic base64(user:pass)` against the expected pair. The split is at the
/// FIRST colon — a password may contain colons, a username may not (RFC 7617).
func proxyAuthorized(_ head: HTTPRequestHead, username: String, password: String) -> Bool {
    guard let value = head.firstValue(of: "Proxy-Authorization") else { return false }
    let parts = value.split(separator: " ", maxSplits: 1).map(String.init)
    guard parts.count == 2, parts[0].caseInsensitiveCompare("Basic") == .orderedSame,
          let decoded = Data(base64Encoded: parts[1]),
          let pair = String(data: decoded, encoding: .utf8),
          let colon = pair.firstIndex(of: ":") else { return false }
    return String(pair[pair.startIndex..<colon]) == username
        && String(pair[pair.index(after: colon)...]) == password
}

func proxyResponse200() -> Data { Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8) }
func proxyResponse407() -> Data {
    Data("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Basic realm=\"DevDeck\"\r\nConnection: close\r\n\r\n".utf8)
}
func proxyResponse400() -> Data { Data("HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n".utf8) }
func proxyResponse502() -> Data { Data("HTTP/1.1 502 Bad Gateway\r\nConnection: close\r\n\r\n".utf8) }

/// One session event in the exact shape `parseGostLogLine` reads (`client`/`sid`/`msg` with the
/// spaced ` <> ` / ` >< ` markers) — the built-in engine feeds the SAME client monitor and LogView.
func builtInSessionLine(open: Bool, client: String, sid: String, port: Int) -> String {
    let object: [String: String] = [
        "client": client,
        "sid": sid,
        "msg": "\(client) \(open ? "<>" : "><") :\(port)",
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else {
        return ""   // unreachable for a [String:String]; parseGostLogLine drops "" harmlessly
    }
    return String(decoding: data, as: UTF8.self)
}
```

- [ ] **Step 4: Run to verify pass** — `-only-testing:DevDeckTests/HTTPProxyParserTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Proxy/HTTPProxyParser.swift DevDeckTests/HTTPProxyParserTests.swift
git commit -m "feat(proxy): pure HTTP parser half of the built-in engine"
```

---

### Task 4: `BuiltInProxyListener` — the NWListener state machine (+ loopback integration test)

**Files:**
- Create: `DevDeck/Proxy/BuiltInProxyListener.swift`
- Test: `DevDeckTests/BuiltInProxyListenerTests.swift`

**Interfaces:**
- Consumes: Task 3's parser API; `RunnerOutput`.
- Produces:

```swift
final class BuiltInProxyListener: @unchecked Sendable {
    /// Bound port once `.started` has been emitted (ephemeral 0 resolves to the real one).
    private(set) var boundPort: UInt16?
    init(port: UInt16, auth: GostAuth?, emit: @escaping @Sendable (RunnerOutput) -> Void)
    func start()
    func stop()   // idempotent; leads to exactly one .terminated(exitCode: 0)
}
```

Event contract (mirrors a gost process): `start()` → `.started(pid: nil)` immediately (the "spawn"; parity with gost, whose `.started` also precedes the socket bind — the exit-IP probe's retry exists for exactly this), then on bind failure one `.line(bind error, .stderr)` + `.terminated(exitCode: 1)`. Per authorized session: open/close `builtInSessionLine` as `.line(_, .stderr)` (gost logs to stderr). `stop()` cancels everything → `.terminated(exitCode: 0)`. Exactly one terminal event ever (guard with a flag under a lock).

- [ ] **Step 1: Write the failing integration test** (real loopback sockets — this is the one test tier above pure functions):

```swift
import XCTest
import Network
@testable import DevDeck

/// Loopback integration: a real NWListener, a real echo server, real bytes both ways.
/// Everything protocol-level is covered by HTTPProxyParserTests; this asserts the plumbing.
final class BuiltInProxyListenerTests: XCTestCase {

    /// Minimal TCP echo server on an ephemeral port; returns (listener to cancel, its port).
    private func startEchoServer() throws -> (NWListener, UInt16) {
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func pump() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, _ in
                    if let data, !data.isEmpty { connection.send(content: data, completion: .idempotent) }
                    if done { connection.cancel() } else { pump() }
                }
            }
            pump()
        }
        let ready = expectation(description: "echo ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        return (listener, listener.port!.rawValue)
    }

    /// Collects emitted RunnerOutput events thread-safely.
    private final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [RunnerOutput] = []
        func append(_ event: RunnerOutput) { lock.lock(); events.append(event); lock.unlock() }
        var snapshot: [RunnerOutput] { lock.lock(); defer { lock.unlock() }; return events }
    }

    func testConnectTunnelCarriesBytesBothWaysAndLogsTheSession() throws {
        let (echo, echoPort) = try startEchoServer()
        defer { echo.cancel() }

        let sink = EventSink()
        let started = expectation(description: "listener started")
        let proxy = BuiltInProxyListener(port: 0, auth: nil) { event in
            sink.append(event)
            if case .started = event { started.fulfill() }
        }
        proxy.start()
        wait(for: [started], timeout: 5)
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        // Raw client: CONNECT to the echo server through the proxy, then echo a payload.
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!, using: .tcp)
        let replied = expectation(description: "CONNECT accepted and payload echoed")
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let connect = "CONNECT 127.0.0.1:\(echoPort) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            client.send(content: Data(connect.utf8), completion: .idempotent)
            client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let response = String(decoding: data ?? Data(), as: UTF8.self)
                XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), "got: \(response)")
                client.send(content: Data("ping-through-tunnel".utf8), completion: .idempotent)
                client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { echoed, _, _, _ in
                    XCTAssertEqual(String(decoding: echoed ?? Data(), as: UTF8.self), "ping-through-tunnel")
                    replied.fulfill()
                }
            }
        }
        client.start(queue: .global())
        wait(for: [replied], timeout: 10)
        client.cancel()

        // The open line must have been logged in the gost shape by now.
        let opened = sink.snapshot.contains { event in
            guard case .line(let text, .stderr) = event,
                  case .sessionOpened = parseGostLogLine(text) else { return false }
            return true
        }
        XCTAssertTrue(opened, "no gost-shaped session-open line; events: \(sink.snapshot)")

        proxy.stop()
        // stop() must produce exactly one clean terminal.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              !sink.snapshot.contains(.terminated(exitCode: 0)) { usleep(50_000) }
        XCTAssertEqual(sink.snapshot.filter { if case .terminated = $0 { return true }; return false },
                       [.terminated(exitCode: 0)])
    }

    func testAuthRequiredGets407WithoutCredentials() throws {
        let sink = EventSink()
        let started = expectation(description: "started")
        let proxy = BuiltInProxyListener(port: 0, auth: GostAuth(username: "dev", password: "pw")) { event in
            sink.append(event)
            if case .started = event { started.fulfill() }
        }
        proxy.start()
        wait(for: [started], timeout: 5)
        defer { proxy.stop() }
        let proxyPort = try XCTUnwrap(proxy.boundPort)

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!, using: .tcp)
        let got407 = expectation(description: "407")
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.send(content: Data("CONNECT x:443 HTTP/1.1\r\n\r\n".utf8), completion: .idempotent)
            client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                XCTAssertTrue(String(decoding: data ?? Data(), as: UTF8.self).hasPrefix("HTTP/1.1 407"))
                got407.fulfill()
            }
        }
        client.start(queue: .global())
        wait(for: [got407], timeout: 10)
        client.cancel()
        // An unauthorized probe is NOT a session — nothing to show in the client list.
        XCTAssertFalse(sink.snapshot.contains { if case .line = $0 { return true }; return false })
    }

    func testOccupiedPortEmitsTerminated1() throws {
        let (blocker, blockedPort) = try startEchoServer()
        defer { blocker.cancel() }
        let sink = EventSink()
        let terminated = expectation(description: "terminated(1)")
        let proxy = BuiltInProxyListener(port: blockedPort, auth: nil) { event in
            sink.append(event)
            if case .terminated(1) = event { terminated.fulfill() }
        }
        proxy.start()
        wait(for: [terminated], timeout: 10)
        // The invariant held: .started came first, and a .line explains the failure.
        if case .started = sink.snapshot.first {} else { XCTFail("first event must be .started") }
        XCTAssertTrue(sink.snapshot.contains { if case .line = $0 { return true }; return false })
    }
}
```

- [ ] **Step 2: Run to verify failure** — `-only-testing:DevDeckTests/BuiltInProxyListenerTests`. Expected: compile error.

- [ ] **Step 3: Implement** `BuiltInProxyListener.swift`. Structure (all on one serial `DispatchQueue(label: "devdeck.proxy.builtin")`, the Network.framework idiom):

```swift
import Foundation
import Network

/// The in-process share listener: HTTP CONNECT + absolute-form forwarding on one port.
///
/// Event contract mirrors a gost PROCESS so `ProcessManager` cannot tell them apart:
/// `.started(pid: nil)` at start (before the bind, like a spawned gost), gost-shaped session
/// `.line`s on stderr, `.terminated(1)` on a bind failure, `.terminated(0)` after `stop()`.
/// Exactly one terminal event, ever.
final class BuiltInProxyListener: @unchecked Sendable {
    private(set) var boundPort: UInt16?

    private let queue = DispatchQueue(label: "devdeck.proxy.builtin")
    private let port: UInt16
    private let auth: GostAuth?
    private let emit: @Sendable (RunnerOutput) -> Void
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]
    private var terminated = false
    private var stopping = false

    init(port: UInt16, auth: GostAuth?, emit: @escaping @Sendable (RunnerOutput) -> Void) { … }

    func start() { /* emit(.started(pid: nil)); create NWListener(using: .tcp, on: port) on `queue`;
        stateUpdateHandler: .ready → boundPort = listener.port?.rawValue;
        .failed(error) → emit .line("bind failed: \(error)", .stderr) + terminal(1);
        newConnectionHandler → wrap in ProxyConnection (below), retain in `connections`,
        remove on its completion callback. */ }

    func stop() { /* on `queue`: stopping = true; cancel every connection (each logs its close
        line), cancel the listener, terminal(0). */ }

    private func terminal(_ code: Int32) { /* once-guard via `terminated`; emit(.terminated(exitCode: code)) */ }
}
```

`ProxyConnection` (private class in the same file) per accepted `NWConnection`:

1. **Accumulate** the head: `receive` loop appending to a buffer until `httpHeadTerminator` is found (`buffer.range(of:)`) or `httpMaxHeadBytes` exceeded (→ send `proxyResponse400()`, cancel).
2. **Parse + classify** via `parseHTTPRequestHead` / `classifyProxyRequest`; `.bad` → 400, cancel.
3. **Auth**: if `auth != nil` and `!proxyAuthorized(head, username: auth.username, password: auth.password)` → send `proxyResponse407()`, cancel. No session line — an unauthorized probe is not a client.
4. **Session open**: `sid = UUID().uuidString.prefix(12)`, `client = "\(ip):\(port)"` extracted from `connection.endpoint` (`case .hostPort(host, port)`; for `.ipv4`/`.ipv6` hosts use `"\(host)"` with any `%en0` scope suffix left as-is — `proxyClientIP` handles brackets, and the monitor only needs a stable string). Emit the open line. From here on, the close line is emitted exactly once on teardown (once-flag).
5. **Dial** the target `NWConnection(host:port:using: .tcp)`. On `.ready`: CONNECT → send `proxyResponse200()` to the client, then forward any bytes that arrived after the head to the target; absolute-form → send `rewrittenHead` + leftover to the target. On `.failed`/`.waiting` timeout → `proxyResponse502()`, cancel.
6. **Pump**: two symmetric `receive(minimumIncompleteLength: 1, maximumLength: 65_536)` loops client→target and target→client; on either side's EOF or error cancel both, emit the close line, invoke the completion callback so the listener releases the connection.

- [ ] **Step 4: Run to verify pass** — `-only-testing:DevDeckTests/BuiltInProxyListenerTests`. Expected: PASS (three tests, real loopback).

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Proxy/BuiltInProxyListener.swift DevDeckTests/BuiltInProxyListenerTests.swift
git commit -m "feat(proxy): in-process NWListener HTTP proxy engine"
```

---

### Task 5: `BuiltInProxyRunner` + routing + `ProxyManager` engine awareness

**Files:**
- Create: `DevDeck/Proxy/BuiltInProxyRunner.swift`
- Modify: `DevDeck/Process/SudoCommandRunner.swift` (the `RoutingCommandRunner` at its top)
- Modify: `DevDeck/Proxy/ProxyManager.swift` (`startShare` diagnostics)
- Test: `DevDeckTests/BuiltInProxyRunnerTests.swift`, additions in `DevDeckTests/ProxyManagerShareTests.swift`

**Interfaces:**
- Consumes: `ProxyShare.builtInCommandPrefix`, `parseBuiltInProxyConfig`, `BuiltInProxyListener`, `CommandRunner`/`RunningProcess`.
- Produces: `struct BuiltInProxyRunner: CommandRunner`; `RoutingCommandRunner` gains `builtInProxy: any CommandRunner = BuiltInProxyRunner()` and dispatches the marker prefix FIRST.

- [ ] **Step 1: Write the failing tests.** `BuiltInProxyRunnerTests.swift`:

```swift
import XCTest
@testable import DevDeck

final class BuiltInProxyRunnerTests: XCTestCase {

    private func markerCommand(configPath: String) -> Command {
        Command(id: ProxyShare.daemonID, name: "Proxy (built-in)",
                command: ProxyShare.builtInCommandPrefix + configPath, isDaemon: true)
    }

    /// Missing config → the same fail-loud shape as `gost -C` on a missing file.
    func testMissingConfigTerminatesWithCode1() async {
        let handle = BuiltInProxyRunner().start(markerCommand(configPath: "/nonexistent/gost.json"))
        var events: [RunnerOutput] = []
        for await event in handle.output { events.append(event) }
        guard case .started = events.first else { return XCTFail("first event must be .started") }
        XCTAssertEqual(events.last, .terminated(exitCode: 1))
        XCTAssertTrue(events.contains { if case .line = $0 { return true }; return false },
                      "the failure must be explained in the log")
    }

    /// End-to-end through the runner: real config file, ephemeral port, stop() → clean exit.
    func testStartsFromConfigFileAndStopsCleanly() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let configPath = dir.appendingPathComponent("gost.json").path
        let json = try XCTUnwrap(ProxyShare(port: 0).gostConfigJSON(password: nil))  // port 0 → ephemeral
        try json.write(toFile: configPath, atomically: true, encoding: .utf8)

        let handle = BuiltInProxyRunner().start(markerCommand(configPath: configPath))
        var events: [RunnerOutput] = []
        for await event in handle.output {
            events.append(event)
            if case .started = event { handle.stop(); handle.stop() }   // idempotent
        }
        XCTAssertEqual(events.last, .terminated(exitCode: 0))
        XCTAssertEqual(events.filter { if case .terminated = $0 { return true }; return false }.count, 1)
    }

    func testRoutingDispatchesMarkerToBuiltInRunner() {
        final class Recorder: CommandRunner, @unchecked Sendable {
            var started: [Command] = []
            func start(_ command: Command) -> any RunningProcess {
                started.append(command)
                return BuiltInProxyRunner().start(command)   // any handle; the test only checks routing
            }
        }
        let builtIn = Recorder(), zsh = Recorder(), sudo = Recorder(), terminal = Recorder()
        let router = RoutingCommandRunner(zsh: zsh, sudo: sudo, terminal: terminal, builtInProxy: builtIn)

        _ = router.start(Command(name: "share", command: ProxyShare.builtInCommandPrefix + "/tmp/x.json"))
        _ = router.start(Command(name: "plain", command: "echo hi"))
        _ = router.start(Command(name: "root", command: "echo hi", needsSudo: true))

        XCTAssertEqual(builtIn.started.map(\.name), ["share"])
        XCTAssertEqual(zsh.started.map(\.name), ["plain"])
        XCTAssertEqual(sudo.started.map(\.name), ["root"])
        XCTAssertTrue(terminal.started.isEmpty)
    }
}
```

Note: `Command(name:command:needsSudo:)` — use the existing memberwise init with defaults; adjust labels to match it exactly.

In `ProxyManagerShareTests`, add engine coverage (following that file's existing fixture pattern for building a `ProxyManager` with injected `gostPath`):

```swift
func testBuiltInEngineStartsWithoutGost() {
    // fixture with gostPath: { _ in nil } and a config whose proxy.engine == .builtIn
    // → startShare() runs the daemon, gostMissing stays false.
}

func testGostEngineWithoutBinarySetsGostMissing() {
    // same fixture but proxy.engine = .gost → startShare() starts nothing, gostMissing == true.
}
```

(Write them as real tests against the file's actual fixture helpers — the two comments above describe the arrange/assert, not placeholders to leave.)

- [ ] **Step 2: Run to verify failure** — `-only-testing:DevDeckTests/BuiltInProxyRunnerTests`. Expected: compile error.

- [ ] **Step 3: Implement.** `BuiltInProxyRunner.swift`:

```swift
import Foundation

/// CommandRunner for the marker command `devdeck:proxy-listen -C <path>` — the built-in share
/// engine. The "process" is an in-process `BuiltInProxyListener`; the stream contract is
/// identical to a spawned gost, which is the whole point: `ProcessManager` supervises both
/// without knowing which engine is behind the daemon.
struct BuiltInProxyRunner: CommandRunner {
    func start(_ command: Command) -> any RunningProcess {
        BuiltInProxyProcess(command: command)
    }
}

/// One run of the built-in listener. `@unchecked Sendable`: mutable state confined to the
/// listener's own serial queue plus a once-flag under a lock (same shape as StreamingProcess).
final class BuiltInProxyProcess: RunningProcess, @unchecked Sendable {
    let token = UUID()
    let output: AsyncStream<RunnerOutput>

    private let continuation: AsyncStream<RunnerOutput>.Continuation
    private let lock = NSLock()
    private var listener: BuiltInProxyListener?
    private var finished = false

    init(command: Command) {
        (output, continuation) = AsyncStream.makeStream(of: RunnerOutput.self, bufferingPolicy: .unbounded)
        let configPath = String(command.command.dropFirst(ProxyShare.builtInCommandPrefix.count))
        guard let data = FileManager.default.contents(atPath: configPath),
              let spec = parseBuiltInProxyConfig(data) else {
            // Same fail-loud shape as `gost -C` on a missing/broken file: the watchdog and the
            // occupied-port machinery upstream see an ordinary daemon that died at birth.
            continuation.yield(.started(pid: nil))
            continuation.yield(.line("built-in proxy: cannot read config at \(configPath)", stream: .stderr))
            finishOnce(.terminated(exitCode: 1))
            return
        }
        let listener = BuiltInProxyListener(port: UInt16(clamping: spec.port), auth: spec.auth) { [weak self] event in
            guard let self else { return }
            if case .terminated = event {
                self.finishOnce(event)
            } else {
                self.continuation.yield(event)
            }
        }
        self.listener = listener
        listener.start()
    }

    func stop() {
        lock.lock(); let listener = self.listener; lock.unlock()
        listener?.stop()   // its terminal event arrives through the emit closure above
    }

    /// Exactly one terminal + finish, no matter how many paths race to it.
    private func finishOnce(_ terminal: RunnerOutput) {
        lock.lock()
        let first = !finished
        finished = true
        lock.unlock()
        guard first else { return }
        continuation.yield(terminal)
        continuation.finish()
    }
}
```

`RoutingCommandRunner` (top of `SudoCommandRunner.swift`): add the parameter and the first-priority branch:

```swift
struct RoutingCommandRunner: CommandRunner {
    let zsh: any CommandRunner
    let sudo: any CommandRunner
    let terminal: any CommandRunner
    let builtInProxy: any CommandRunner

    init(
        zsh: any CommandRunner = ZshCommandRunner(),
        sudo: any CommandRunner = SudoCommandRunner(),
        terminal: any CommandRunner = GhosttyCommandRunner(),
        builtInProxy: any CommandRunner = BuiltInProxyRunner()
    ) { … }

    func start(_ command: Command) -> any RunningProcess {
        // The marker never reaches a shell: an in-process listener, not a process.
        if command.command.hasPrefix(ProxyShare.builtInCommandPrefix) { return builtInProxy.start(command) }
        if command.openInTerminal { return terminal.start(command) }
        return command.needsSudo ? sudo.start(command) : zsh.start(command)
    }
}
```

`ProxyManager.startShare()`: the `guard let command = shareCommand()` failure branch now means exactly "gost engine, no binary" — keep `gostMissing = true` and the existing log line; add `gostMissing = false` on the success path (already there). No other manager change.

- [ ] **Step 4: Run to verify pass** — `-only-testing:DevDeckTests/BuiltInProxyRunnerTests -only-testing:DevDeckTests/ProxyManagerShareTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Proxy/BuiltInProxyRunner.swift DevDeck/Process/SudoCommandRunner.swift DevDeck/Proxy/ProxyManager.swift DevDeckTests/BuiltInProxyRunnerTests.swift DevDeckTests/ProxyManagerShareTests.swift
git commit -m "feat(proxy): built-in engine behind RoutingCommandRunner"
```

---

### Task 6: Announce `proto` per engine

**Files:**
- Modify: `DevDeck/Proxy/ProxyDiscovery.swift` (`ProxyAdvertisement`, `proxyTXTRecord`)
- Modify: `DevDeck/Proxy/ProxyManager.swift` (`startAdvertising`)
- Test: additions in the test file that already covers `proxyTXTRecord` (find it: `grep -rln proxyTXTRecord DevDeckTests/`)

**Interfaces:**
- Produces: `ProxyAdvertisement.proto: String = "http+socks"` (defaulted `var` — every existing construction site keeps compiling); `proxyTXTRecord` emits `"proto": ad.proto`.

- [ ] **Step 1: Write the failing test** (in the existing TXT-record test class):

```swift
func testTXTRecordCarriesTheEngineProto() {
    var ad = ProxyAdvertisement(serviceName: "mac", port: 9999, authRequired: false, host: "192.168.31.5")
    ad.proto = "http"
    XCTAssertEqual(proxyTXTRecord(ad)["proto"], "http")
    // Default stays the historical value — a gost share announces exactly what it used to.
    XCTAssertEqual(proxyTXTRecord(ProxyAdvertisement(serviceName: "mac", port: 9999,
                                                     authRequired: false, host: "192.168.31.5"))["proto"],
                   "http+socks")
}
```

(Match the file's actual `ProxyAdvertisement` construction style; add `exitIP:` if its init requires it.)

- [ ] **Step 2: Run to verify failure** — the covering test class. Expected: compile error (`proto` not a member).

- [ ] **Step 3: Implement.** `ProxyAdvertisement` gains `/// Protocols the listener speaks — "http" (built-in) or "http+socks" (gost).` `var proto: String = "http+socks"`. `proxyTXTRecord`: `"proto": ad.proto`. `ProxyManager.startAdvertising()` sets it when building the ad:

```swift
var ad = ProxyAdvertisement(serviceName: share.effectiveServiceName, port: share.port,
                            authRequired: share.authEnabled, host: host, exitIP: nil)
ad.proto = share.engine == .builtIn ? "http" : "http+socks"
```

(`rememberedProxy`'s hardcoded `"http+socks"` stays — `DiscoveredProxy.proto` is display-only and the cache does not record it.)

- [ ] **Step 4: Run to verify pass** — the covering test class + `ProxyManagerShareTests`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/Proxy/ProxyDiscovery.swift DevDeck/Proxy/ProxyManager.swift DevDeckTests/
git commit -m "feat(proxy): announce proto per share engine"
```

---

### Task 7: Editor picker + quit-dialog exclusion

**Files:**
- Modify: `DevDeck/MainWindow/ProxyShareEditorView.swift`, `DevDeck/Localization/L10n.swift`, `DevDeck/AppDelegate.swift`

**Interfaces:**
- Consumes: `ProxyEngine`, `draft.engine`, `proxy.gostMissing`, `manager.aliveDaemons`, `ProxyShare.daemonID`, `store.config.proxy.engine`.
- Produces: `L10n.proxyEngine`, `L10n.proxyEngineBuiltIn`, `L10n.proxyEngineGost`, `L10n.proxyEngineHint`.

UI is not unit-tested in this project; the check is a build + the manual smoke in Task 8.

- [ ] **Step 1: L10n strings** (next to the other proxy strings):

```swift
static var proxyEngine: String { t("Engine", "Движок") }
static var proxyEngineBuiltIn: String { t("Built-in", "Встроенный") }
static var proxyEngineGost: String { t("gost (system)", "gost (системный)") }
static var proxyEngineHint: String {
    t("Built-in serves HTTP (CONNECT) — enough for every DevDeck client and dp. Pick gost if a peer needs SOCKS.",
      "Встроенный отдаёт HTTP (CONNECT) — этого достаточно всем клиентам DevDeck и dp. gost нужен, только если пиру требуется SOCKS.")
}
```

- [ ] **Step 2: The picker** in `shareSection`, directly under the share toggle (before the port field):

```swift
Picker(L10n.proxyEngine, selection: $draft.engine) {
    Text(L10n.proxyEngineBuiltIn).tag(ProxyEngine.builtIn)
    Text(L10n.proxyEngineGost).tag(ProxyEngine.gost)
}
.pickerStyle(.segmented)
Text(L10n.proxyEngineHint).font(.caption).foregroundStyle(.secondary)
```

The existing `if proxy.gostMissing { warning(L10n.gostNotFound) }` becomes
`if draft.engine == .gost && proxy.gostMissing { … }` — the warning is about the engine the user is choosing, not the one that failed last. `shareHasChanges` already covers `engine` (it compares whole `ProxyShare` values), so Save → `saveShare()` → restart applies an engine switch with zero extra code.

- [ ] **Step 3: Quit dialog** — in `AppDelegate.applicationShouldTerminate`, replace the first line:

```swift
// The built-in listener is in-process: it cannot be "kept in background", and the share
// auto-restores on the next launch (proxyShareEnabled) — so it neither triggers the dialog
// nor gets counted. The gost engine keeps today's behavior (a real process can survive us).
let daemons = manager.aliveDaemons.filter {
    !($0 == ProxyShare.daemonID && store.config.proxy.engine == .builtIn)
}
```

- [ ] **Step 4: Build** — `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild build -project DevDeck.xcodeproj -scheme DevDeck -configuration Debug -derivedDataPath build/dd 2>&1 | tail -5`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add DevDeck/MainWindow/ProxyShareEditorView.swift DevDeck/Localization/L10n.swift DevDeck/AppDelegate.swift
git commit -m "feat(proxy): engine picker in the share editor, quit dialog skips the in-process listener"
```

---

### Task 8: Full suite, manual smoke, docs

**Files:**
- Modify: `README.md`, `CHANGELOG.md`

- [ ] **Step 1: Full test run** — `DEVELOPER_DIR=/Applications/Xcode.app xcodebuild test -project DevDeck.xcodeproj -scheme DevDeck -destination 'platform=macOS' 2>&1 | tail -15`. Expected: `TEST SUCCEEDED` — the whole suite, not only the new classes.

- [ ] **Step 2: Manual smoke** (run the Debug build): Proxy page → engine "Built-in" → enable the share → the popover row shows "Proxy (built-in)" running; `curl -x http://127.0.0.1:9999 https://api.ipify.org` answers with the egress IP and the machine appears under Connected; switch the picker to gost and back → Save restarts the listener. Report the transcript of what was checked to the user — do not skip this step silently.

- [ ] **Step 3: Docs.**
  - `README.md`: in Features, reword the Proxy Manager bullet — the share runs on a **built-in HTTP proxy engine** by default; `gost` is an optional alternative engine for SOCKS clients. In Requirements, demote `gost` accordingly ("only for the gost engine — SOCKS support").
  - `CHANGELOG.md`: an Unreleased entry describing the built-in engine, the `engine` config key (default `builtIn`), and the changed default for existing configs (SOCKS users: switch the engine back to gost in the editor).

- [ ] **Step 4: Commit**

```bash
git add README.md CHANGELOG.md
git commit -m "docs: built-in proxy engine"
```

---

## Self-Review

- **Spec coverage:** Part 1 (model) → Task 1; Part 2 (marker + config read-back) → Tasks 1, 2, 5; Part 3 (parser + listener + runner) → Tasks 3, 4, 5; Part 4 (UI, quit dialog, proto, docs) → Tasks 6, 7, 8; Part 5 (tests) → embedded per task + Task 8's full run and manual smoke. No gaps.
- **Placeholder scan:** Task 4 Step 3 sketches `start()`/`stop()` bodies as guided comments next to a full skeleton and a complete behavioral contract with three executable tests — the intended level for an NWListener state machine; everything else is verbatim code. `ProxyManagerShareTests` additions in Task 5 describe arrange/assert against fixtures the implementer must read in place — flagged explicitly as "write as real tests".
- **Type consistency:** `builtInCommandPrefix`, `parseBuiltInProxyConfig(_:) -> (port: Int, auth: GostAuth?)?`, `BuiltInProxyListener(port:auth:emit:)`, `boundPort`, `builtInSessionLine(open:client:sid:port:)`, `ProxyAdvertisement.proto` — names match across tasks 1–7.
