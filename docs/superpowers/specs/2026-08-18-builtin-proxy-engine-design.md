# Design: Built-in Proxy Engine

> Date: 2026-08-18. Status: designed, ready to implement.
> Builds on the Proxy Manager (0.5.0+) — `docs/proxy-manager-plan.md`,
> `docs/superpowers/specs/2026-08-06-proxy-connected-clients-design.md`.

## Problem

The share side of the Proxy Manager requires an external `gost` binary installed via Homebrew.
That is the feature's only external dependency: without `gost` the share cannot start at all, the
editor shows a warning, and the app's "zero dependencies" story has an asterisk. There is also no
way to exercise the share pipeline without first installing a third-party tool.

## Goal

An in-process HTTP proxy listener built on `Network.framework`, selectable per share as the
**engine**: `builtIn` (the new default) or `gost` (the current behavior, kept for SOCKS clients).
Switching engines changes nothing else — announcement, client monitoring, routing, credentials and
supervision behave identically from the outside.

## Decisions

| Question | Decision |
|---|---|
| Protocols (built-in) | HTTP only: CONNECT + absolute-form requests. No SOCKS — DevDeck's own routing and `dp` emit only `http://` URLs |
| Default engine | `builtIn`, including existing configs with no `engine` key. SOCKS users switch back to `gost` in the editor |
| Architecture | The built-in listener is a `CommandRunner` — the share stays a synthetic daemon and every downstream consumer is untouched |
| Config file | Both engines start from the same generated 0600 `gost.json`; the built-in engine reads `addr` + `auth` back out of it |
| Session events | The built-in listener logs gost-shaped JSON lines, so `ProxyClientMonitor` and the LogView work unchanged |
| Auth | `Proxy-Authorization: Basic` checked against the config's `auth` block; `407` + `Proxy-Authenticate` otherwise |
| Schema | No `schemaVersion` bump — `engine` decodes with a default, older builds ignore the unknown key |
| Quit dialog | The built-in listener is excluded from `aliveDaemons` — it cannot survive the app, and the share auto-restores on the next launch |

### Why a CommandRunner and not a ProxyManager-level engine abstraction

The share is already expressed as a synthetic daemon `Command` precisely so that supervision —
watchdog restarts, the occupied-port pre-check and panel, the popover row, state observation for
the Bonjour announcement, the client monitor fed from the daemon's log stream — is the existing
engine's job. A `ProxyShareEngine` protocol at the `ProxyManager` level would fork every one of
those consumers into a second state path for no behavioral gain. Implementing the listener as a
fourth runner behind `RoutingCommandRunner` (next to zsh/sudo/terminal) keeps the contract: from
`ProcessManager` outward, the built-in engine is indistinguishable from `gost`.

What the existing machinery gives the built-in engine for free:

- **Port conflicts.** The proactive pre-check and the watchdog's occupied-port pause key off
  `command.port`, before the runner is ever started. An orphaned `gost` left behind by a previous
  version surfaces as an occupied port and the existing panel offers to kill it.
- **Watchdog.** A listener that dies (bind failure at start, later socket error) emits
  `.terminated(code != 0)` and gets the same restart/pause policy as any daemon.
- **Adoption.** `adoptSurvivingDaemons` matches `ps` argv; the built-in marker command never
  matches a real process, so adoption degrades to a no-op — correct, since an in-process listener
  cannot outlive the app.

## Part 1 — Model: the engine choice

`ProxyShare` gains:

```swift
enum ProxyEngine: String, Codable { case builtIn, gost }
var engine: ProxyEngine   // decodeIfPresent ?? .builtIn
```

- `toCommand(gostPath:configPath:)` splits: the gost branch is unchanged; the built-in branch
  produces `command: "devdeck:proxy-listen -C \(shellQuote(configPath))"` with the same fixed
  `daemonID`, `isDaemon`, `watchdogEnabled`, `port`.
- `gostPath` / `gostMissing` are consulted only when `engine == .gost`; with the built-in engine
  `ProxyManager.startShare()` never checks for the binary.
- The TXT record's `proto` value moves from a hardcoded string into `ProxyAdvertisement`:
  `"http"` for `builtIn`, `"http+socks"` for `gost`. (`DiscoveredProxy.proto` is display-only —
  no client-side branching.)

## Part 2 — Routing: the marker command

`RoutingCommandRunner` gains a fourth branch, checked first:

```swift
if command.command.hasPrefix("devdeck:proxy-listen") { return builtInProxy.start(command) }
```

`BuiltInProxyRunner: CommandRunner` parses the config path out of the command string (the only
argument, shell-quoted), reads the generated `gost.json`, and starts the listener. Reusing the
config file — rather than passing port/auth through `Command` — keeps the password out of argv,
out of `Command` (which is logged and shown), and keeps `saveShare`'s restart-on-change semantics
(`writeShareConfig` → stop → start) identical for both engines. A missing or unparsable config
emits `.started(nil)` then `.terminated(1)` with one explanatory `.line` — same fail-loud shape as
`gost -C` on a missing file.

The config slice it reads back: `services[0].addr` (`":PORT"`) and `services[0].handler.auth`
(optional `username`/`password`). `GostConfig` and friends become `Codable` (they are
encode-only today).

## Part 3 — The listener

New files under `DevDeck/Proxy/`:

- **`HTTPProxyParser.swift`** — pure functions, no I/O:
  - parse a request head (everything up to `\r\n\r\n`): method, target, version, headers;
    reject anything malformed.
  - classify: `CONNECT host:port` → tunnel; absolute-form (`GET http://host[:port]/path`) →
    forward; anything else → `400`.
  - auth check: compare `Proxy-Authorization: Basic <b64>` against the expected user:pass;
    constant response builders for `200 Connection Established`, `407` (with
    `Proxy-Authenticate: Basic realm="DevDeck"`), `400`, `502`.
  - absolute-form rewrite: request line to origin-form, drop `Proxy-Connection` /
    `Proxy-Authorization` headers, leave the rest of the head byte-identical.
- **`BuiltInProxyListener.swift`** — the `NWListener` + per-connection state machine:
  - bind on the configured port; ready → emit `.started(nil)`; bind failure → one `.line` with
    the error and `.terminated(1)`.
  - per connection: accumulate bytes until the head is complete (cap the head at 64 KiB —
    over-cap or malformed → `400` and close), run the parser, enforce auth, dial the target via
    `NWConnection`, reply, then pump bytes both ways until either side closes. CONNECT forwards
    any bytes that arrived after the head; absolute-form forwards the rewritten head plus the
    remainder, and from then on the connection is an opaque tunnel (keep-alive to a *different*
    host on the same connection is not supported — CLI clients reuse per-host).
  - dial failures → `502` (CONNECT) / close (mid-tunnel).
  - session accounting: on the first successful auth+parse emit the gost-shaped open line, on
    connection teardown the close line, with a per-connection `sid` and the peer's `IP:port`:

    ```json
    {"client":"192.168.31.42:55904","msg":"192.168.31.42:55904 <> :9999","sid":"b1a2…"}
    {"client":"192.168.31.42:55904","msg":"192.168.31.42:55904 >< :9999","sid":"b1a2…"}
    ```

    (`parseGostLogLine` keys on the spaced ` <> ` / ` >< ` markers and the three string fields;
    the exact remainder of `msg` is free.)
  - `stop()`: cancel the listener and every open connection, then `.terminated(0)`.
- **`BuiltInProxyRunner.swift`** — the thin `CommandRunner` adapter: config parsing, one
  `RunningProcess` handle per start (fresh `token`, single-consumer `AsyncStream`, idempotent
  `stop()`), events marshalled off Network.framework's queues into the stream.

Concurrency: the listener and its connections live on a dedicated serial `DispatchQueue` (the
Network.framework idiom); the `RunningProcess` contract already requires only that events arrive
on the stream, and `ProcessManager` hops to the main actor itself.

## Part 4 — UI and lifecycle

- **Share editor**: an "Engine" picker (Built-in / gost (system)) above the port field. The
  "gost not found" warning renders only when the picker says gost. L10n strings EN/RU.
- **Quit dialog**: `ProcessManager.aliveDaemons` excludes the built-in listener's `daemonID`
  when its run came from the marker command — "keep in background" cannot apply to an in-process
  listener, and `proxyShareEnabled` restarts the share on the next launch anyway. With the gost
  engine the dialog behaves exactly as today.
- **README / CHANGELOG**: `gost` becomes optional-for-SOCKS; the engine choice documented.

## Part 5 — Testing

Unit (no sockets):

- `HTTPProxyParser`: CONNECT, absolute-form GET/POST, origin-form rejection, header parsing,
  auth accept/reject (missing header, wrong scheme, wrong credentials, credentials with `:`),
  the 407/400/502/200 builders, absolute-form rewrite (line, dropped headers, preserved body
  prefix), head-size cap.
- Config read-back: `gostConfigJSON` output round-trips through the runner's parser (port, auth
  present/absent) — the writer and the reader are asserted against each other.
- `RoutingCommandRunner` routes the marker command to the injected built-in runner and leaves
  zsh/sudo/terminal routing untouched.
- `ProxyShare`: `engine` decoding default, `toCommand` per engine, `gostMissing` only for gost.
- Session lines: the listener's open/close lines parse back through `parseGostLogLine`.

Integration (one test, real loopback): start the listener on an ephemeral port with a local echo
server as the target, CONNECT through it, assert the tunnel carries bytes both ways and the
session lines appear.

Manual dogfood: switch this machine's own share to the built-in engine and live on it — the
feature's stated purpose.

## Out of scope

- SOCKS5 in the built-in engine (the gost engine remains for that).
- Plain-HTTP keep-alive to multiple hosts over one client connection.
- UDP, IPv6-specific handling beyond what `NWConnection` gives for free, traffic accounting.
