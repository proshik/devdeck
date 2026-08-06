# Design: Connected Clients on the Proxy Host

> Date: 2026-08-06. Status: designed, ready to implement.
> Builds on the Proxy Manager (0.5.0) and the terminal helper (0.6.0) —
> `docs/superpowers/specs/2026-07-26-proxy-env-and-directory-prompt-design.md`.

## Problem

A machine that shares its VPN egress has no idea whether anyone is using it. The host sees its own
listener is up and announced, and that is all: whether a colleague actually connected, whether they
are still connected, and how many machines are on the share is invisible. The usual question —
"did my proxy work for you?" — is answered over chat rather than by looking at the app.

## Goal

On the host side, show which machines are using the share right now and which used it in the last
few minutes, with a name where one can be resolved. Read-only observation. No traffic accounting,
no destination hosts, no way to kick a client.

## Decisions

| Question | Decision |
|---|---|
| Data source | Parse the `gost` listener's own stderr, already streamed through `ProcessManager` |
| Depth | Who is connected now + who was recently; **no** byte counters, **no** destination hosts |
| Identity | Reverse mDNS via `getnameinfo`, falling back to the bare IP |
| Where in the UI | Full list on the Proxy page; a single `connected N` word in the popover |
| Persistence | None — in-memory, for the current app session |
| Loopback | `127.0.0.1` is filtered out (it is our own exit-IP probe and the local `dp`) |

### Why the log stream and not the alternatives

`gost` v3 logs one JSON object per session event to stderr, and `ProcessManager` already pipes that
into `logs[ProxyShare.daemonID]`. The data is on hand: no new process, no new listening port, and
both edges — connect and disconnect — arrive as events rather than being inferred from polling.

Rejected: polling `lsof -nP -iTCP:<port> -sTCP:ESTABLISHED` on a timer spawns an external process
every few seconds and only ever sees "right now" — the recent-history half would still have to be
accumulated by hand, so it costs more and delivers less. Also rejected: enabling `gost`'s API
service, which opens another port on the machine and reports per-service counters, not the
per-client list this feature is about.

The cost of the choice is a dependency on gost's log format, and no data at all for an **adopted**
listener (an orphan has no pipe). The latter is not a regression: adoption of this daemon has never
worked, for the reason recorded in `ProxyShare.toCommand` — a surviving `gost` surfaces as an
occupied port instead.

## Part 1 — The parser

New file `DevDeck/Proxy/ProxyClientLog.swift`. Pure, no dependencies, trivially testable.

```swift
enum ProxyClientEvent: Equatable {
    case sessionOpened(client: String, sid: String)   // client == "192.168.31.42:55904"
    case sessionClosed(sid: String)
}

func parseGostLogLine(_ line: String) -> ProxyClientEvent?
```

Verbatim samples from `gost 3.2.6`, captured from a live listener (keys elided for width):

```
{"client":"192.168.31.42:55904","kind":"handler","msg":"192.168.31.42:55904 <> 192.168.31.5:9999","sid":"d9q51fl…"}
{"client":"192.168.31.42:55904","kind":"handler","msg":"192.168.31.42:55904 <-> api.ipify.org:443","sid":"d9q51fl…"}
{"client":"192.168.31.42:55904","duration":297735250,"msg":"192.168.31.42:55904 >-< api.ipify.org:443","sid":"d9q51fl…"}
{"client":"192.168.31.42:55904","duration":435225125,"inputBytes":706,"msg":"192.168.31.42:55904 >< 192.168.31.5:9999","outputBytes":3105,"sid":"d9q51fl…"}
```

Rules:

- The line must parse as a JSON object carrying both `client` and `sid` (strings). Anything else —
  service startup lines, non-JSON output, a future format — returns `nil`.
- `msg` contains ` <> ` → `.sessionOpened`. `msg` contains ` >< ` → `.sessionClosed`.
- ` <-> ` and ` >-< ` are per-destination dials **inside** a session and are ignored. The spaces
  matter: the four separators are distinguishable only with them.
- `inputBytes` / `outputBytes` / `host` / `dst` are deliberately not read. The feature does not
  account traffic and does not look at where peers go.

`JSONSerialization` rather than `Codable`: the input is a foreign schema most of whose keys we do
not want, and a throwing decoder per line would be noise.

## Part 2 — The model

New file `DevDeck/Proxy/ProxyClientMonitor.swift`.

```swift
@MainActor @Observable
final class ProxyClientMonitor {
    struct Client: Identifiable, Equatable {
        let ip: String
        var hostname: String?      // resolved, .local stripped; nil → show the IP
        var liveSessions: Int
        let firstSeen: Date
        var lastSeen: Date
        var isActive: Bool = false // computed at publish time, not called on demand by the view
        var id: String { ip }
    }

    private(set) var clients: [Client] = []   // active first, then by lastSeen descending
    var activeCount: Int { … }

    func ingest(_ line: String)
    func listenerDidStart()
    func listenerDidStop()
    func clear()
}
```

Internal state: `sessions: [String: String]` (sid → IP) and `entries: [String: Client]` keyed by IP.

`.sessionOpened` increments `liveSessions` for the IP and records the sid; `.sessionClosed` looks
the sid up and decrements. Both stamp `lastSeen`. A sid that closes without a recorded open is
ignored (it belongs to a previous listener process).

### Two time windows

- **Active** — `liveSessions > 0` **or** `lastSeen` within **2 minutes**.
- **Retained** — kept in the list, dimmed, until `lastSeen` is **10 minutes** old, then swept.

The active window is the point of the whole model. Proxy sessions are short: between two HTTP
requests a client genuinely has zero open sessions, and a naive "who is connected right now" list
would blink empty every few seconds and make the popover counter flap 1 → 0 → 1.

The sweep runs on a 15-second repeating task, armed on the listener's first bring-up. Once armed it
keeps running for the monitor's whole lifetime — the listener going up or down again does not
re-arm or tear it down; only an explicit `stopShare()` (`clear()`) cancels it.

### Publishing

Events land in `entries`; `clients` is rebuilt at most every 500 ms via a coalescing task, and only
when something actually changed. A browser behind the proxy produces two events per request, so a
busy peer can generate hundreds of events a second — that must not translate into hundreds of
SwiftUI invalidations.

### Injected dependencies (probe pattern, as everywhere else in this subsystem)

- `now: () -> Date` — so the window and sweep logic is tested without waiting.
- `naming: any ProxyClientNaming` — reverse lookups.

### Lifecycle

- `listenerDidStart()` drops all live sessions and sids (the process that owned them is gone) but
  keeps the entries, so a watchdog restart does not erase the list of who was just here. Also arms
  the sweep, once, on the listener's first bring-up.
- `listenerDidStop()` does the same session/sid reset for the listener going down on its own —
  a watchdog that gives up (or a bring-up with no LAN address to announce) must not leave a session
  pinned forever. The entries stay, exactly as `listenerDidStart()` leaves them.
- `clear()` wipes everything, including the sweep task itself.

## Part 3 — Names

```swift
protocol ProxyClientNaming: Sendable {
    func hostname(for ip: String) async -> String?
}
```

Live implementation calls `getnameinfo` with `NI_NAMEREQD` on a `sockaddr_in`, off the main thread
(`Task.detached`). In-process — macOS resolves `.local` reverse lookups through mDNSResponder
itself, so no `dns-sd` subprocess is needed. A trailing `.local` is stripped, matching what
`ProxyShare.defaultServiceName` already does to this machine's own host name.

Each new IP is resolved once. A success is cached for the app session. A failure is cached for
5 minutes and then retried while the client is still visible — a peer can appear a moment before
its mDNS record does. An unresolved client shows its IP, which is never worse than today.

## Part 4 — Wiring

`ProcessManager` gets one hook, in the style of the existing `proxyRouting`:

```swift
@ObservationIgnored var outputObserver: (UUID, String, OutputChannel) -> Void = { _, _, _ in }
```

called from `apply` in the `.line` case, next to `appendLog`. `ProcessManager` stays ignorant of
proxy types: `AppDelegate` wires the closure to `ProxyManager`, which filters for
`ProxyShare.daemonID` and forwards to the monitor. One closure call per log line for every command
is negligible, and keeping the filter out of `ProcessManager` keeps the hook generic.

`ProxyManager` owns the monitor and re-exposes exactly two members of it —
`var proxyClients: [ProxyClientMonitor.Client]` and `var connectedClientCount: Int` (the monitor's
`clients` and `activeCount`) — so views read the one object they already read for `isAdvertising`
and `lastExitIP`.

Calls into the monitor:

- `syncAdvertising()` tracks the daemon's own `.daemonRunning` state directly — independent of
  whether Bonjour ends up announcing it, since `startAdvertising()` also bails out with no LAN
  address, and the share toggle can withdraw the announcement while `gost` keeps running. The up
  edge calls `monitor.listenerDidStart()`, the down edge `monitor.listenerDidStop()`; each fires
  exactly once per transition, including a watchdog restart, because it is gated on a change from
  the listener's own last-known state rather than on `isAdvertising`.
- `stopShare()` → `monitor.clear()`.

## Part 5 — UI

### Main window, Proxy page (`ProxyShareEditorView`)

A subsection under the share section, rendered only when `proxyShareEnabled`. One row per client:

- a `laptopcomputer` icon,
- the hostname, or the IP when unresolved, with the IP beneath it in a monospaced caption,
- on the right, for an active client a green dot and its live-session count; for a retained one, a
  relative "5 min ago" in secondary colour.

Empty state: "Nobody has connected yet" / «Пока никто не подключался».

### Popover (`ProxySectionView`)

No new block — the popover stays minimal, per the locked architecture. One segment is appended to
the existing announcement line:

```
📶 Announced on the network · 91.108.4.2 · connected 2
```

Only active clients are counted, and the segment is omitted at zero. The wording is `connected N`
(«подключено N») on purpose: it sidesteps Russian numeral agreement, so no plural helper is needed
in `L10n`.

## Part 6 — Tests

`ProxyClientLogParserTests` — the verbatim gost lines above: open, close, both intra-session
separators ignored, a service startup line ignored, non-JSON ignored, JSON without `sid`/`client`
ignored.

`ProxyClientMonitorTests` — with an injected clock and a fake `ProxyClientNaming`:

- two sessions from one IP → one client, `liveSessions == 2`; closing one leaves 1.
- two IPs → two clients; `activeCount == 2`.
- a client with no live sessions stays active inside the 2-minute window and stops being active
  after it.
- a client is swept after 10 idle minutes, and not before.
- `listenerDidStart()` zeroes live sessions but keeps entries and their `lastSeen`.
- a close for an unknown sid changes nothing.
- `127.0.0.1` never produces a client.
- a resolved hostname reaches the client; a failing resolver leaves `hostname == nil`.

No sockets, no processes, no mDNS — consistent with the rest of the proxy subsystem.

## Out of scope

- Byte counters and per-client traffic totals.
- The list of destination hosts a peer visits (available in the log, deliberately not read — it is
  someone else's browsing history).
- Kicking or blocking a client.
- Persisting the list across app restarts.
- Naming clients by hand.
