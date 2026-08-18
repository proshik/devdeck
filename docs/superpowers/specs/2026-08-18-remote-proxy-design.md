# Design: Remote Proxy over SSH (VDS)

> Date: 2026-08-18. Status: designed, ready to implement.
> Builds on the Proxy Manager client side and the built-in proxy engine (0.12.0) —
> `docs/superpowers/specs/2026-08-18-builtin-proxy-engine-design.md`.

## Problem

The Proxy Manager's client side can only use a proxy announced by another DevDeck on the same
LAN. When there is no second Mac, the natural egress is a VDS rented in a country where
Anthropic's services are reachable (the developer's Mac is in a jurisdiction where they are not).
Today DevDeck cannot route a flagged command — `claude` above all — through such a machine, and
the browser half of Claude Code's `/login` has no proxied path at all: the OAuth page opens in the
system browser, which egresses directly and cannot reach the login page.

## Goal

A **remote proxy**: pick a VDS reachable over SSH, and flagged commands, the `dp` helper and a
dedicated browser window all egress through it — with nothing installed or configured on the VDS
beyond `sshd`, and nothing exposed to the internet. The existing LAN scenario is untouched and
the two kinds of proxy are selectable from the same list.

## Decisions

| Question | Decision |
|---|---|
| Transport | `ssh -N -D 127.0.0.1:<socksPort> <destination>` — dynamic SOCKS over the user's ssh key. Zero VDS-side software |
| HTTP face | A second instance of the built-in engine (the **bridge**) on `127.0.0.1:<localPort>`, dialing targets through the SOCKS upstream — every existing `http://` consumer works unchanged |
| VDS egress | The VDS's own public IP (no VPN on it); the check button showing that IP is the proof the route works |
| Tunnel lifecycle | Both daemons (tunnel + bridge) are held up while the remote proxy is selected, stopped when it is deselected |
| Tunnel command | Auto-created as a regular, visible, editable deck command; DevDeck stores only its id |
| Auth | None: the entry point is loopback; authentication is the ssh key |
| Selection model | New `Settings.activeRemoteProxyID`, mutually exclusive with `activeProxyName` — the discovered-proxy path stays untouched |
| `dp` scope check | `DEVDECK_PROXY_LAN=*` means "valid on any network" — loopback endpoints do not depend on the LAN |
| Browser login | A "Browser via proxy" button launches a separate Chrome instance with `--proxy-server` and its own profile |
| DNS | Hostnames must be resolved by the VDS (SOCKS5 domain address type), never locally — a blocked domain resolves poisoned or not at all on the Mac |

### Why ssh -D + a local bridge, and not gost on the VDS

The first draft ran gost on the VDS (`ssh -L` to a loopback-bound listener, later
`ssh <dest> exec gost` inside the tunnel command). Both variants require installing a binary on
the VDS — architecture detection, a pinned version, an idempotent setup script, an update story.
`ssh -D` deletes that whole surface: the only remote dependency is `sshd`, which defines "a VDS
reachable over SSH". The cost is a SOCKS-to-HTTP gap on the Mac — and the built-in engine
shipped in 0.12.0 is precisely an HTTP CONNECT/absolute-form listener whose target dial is one
function; giving that dial an optional SOCKS upstream is a small extension to code this project
owns and covers with loopback socket tests.

**Fallback, documented up front:** the design's one external risk is `ProxyConfiguration`
behavior (see Part 3). If the spike shows hostnames being resolved locally, the bridge keeps its
role and only the transport reverts to the first draft — `ssh -L` to a gost bound to the VDS's
loopback — without changing the model, the UI, or the routing. The risk gates one function, not
the architecture.

## Part 1 — Model

New client-side entity in config.json (top-level key `remoteProxies`, resilient decoding, no
schema bump):

```swift
struct RemoteProxy: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String              // what the list shows; also the Bonjour-independent identity
    var localPort: Int            // the bridge's HTTP port on the Mac (default 18888)
    var socksPort: Int            // ssh -D's SOCKS port on the Mac (default 1080)
    var tunnelCommandID: UUID?    // the ssh daemon command created for (or assigned to) this proxy
}
```

`Settings` gains `activeRemoteProxyID: UUID?`. Selecting a remote proxy clears
`activeProxyName` (and its remembered-endpoint cache); selecting a discovered proxy clears
`activeRemoteProxyID`. Exactly one of the two is ever set.

The **create flow** asks for name, ssh destination (`vds` from `~/.ssh/config`, or `user@host`)
and the two ports (defaulted), then creates a regular deck command —

```
ssh -N -D 127.0.0.1:1080 vds
```

— with `isDaemon`, `watchdogEnabled`, `port: socksPort`, stores its id in `tunnelCommandID`, and
saves both. The command is the user's after that: editing it (a `-J` jump host, options) is
editing any other command. Deleting a remote proxy offers to delete its tunnel command;
deleting the tunnel command directly leaves the proxy listed but permanently unusable (the
editor shows which command is missing).

## Part 2 — Resolution and routing

`ProxyManager.activeProxy` learns the second kind. A selected remote proxy resolves to a
synthetic `DiscoveredProxy(name:, host: "127.0.0.1", port: localPort, authRequired: false,
proto: "http", isLive: <both daemons running>)` so everything downstream — `resolvedEndpoint()`,
`routing(for:)`, `checkActiveProxy()`, `proxyURL` — is reused verbatim.

Usability is binary and loud, as today, and the guard lives in `resolvedEndpoint()` — the single
place `routing(for:)`, the check button and `proxy.env` already share: for the remote kind it
returns nil unless BOTH daemons are in `daemonRunning`, so a flagged run fails explicitly with
`.unavailable`. `isLive` on the synthetic value only drives the UI (dimming), exactly like a
remembered discovered proxy. No LAN-prefix scoping applies: a loopback endpoint is valid on any
network — whether the route actually works is the tunnel's problem, and the check button answers
it with the VDS's public IP. (`refreshProxyEnvFile()`'s "no LAN address → remove the file" guard
also does not apply to the remote kind — a Mac on ethernet-less Wi-Fi-less VPN can still reach
its own loopback.)

`refreshProxyEnvFile()` writes `DEVDECK_PROXY_LAN=*` for a remote proxy. The `dp` snippet gains
one clause — `[[ $lan == "*" ]] ||` in front of the network check — which is a **snippet version
change**: users must re-paste it from the Proxy page (the README and CHANGELOG say so).

## Part 3 — The bridge (built-in engine + SOCKS upstream)

`BuiltInProxyListener` gains an optional upstream: `init(port:auth:upstream:emit:)` where
`upstream: NWEndpoint?` is a SOCKS5 proxy. The only changed behavior is the target dial: with an
upstream set, the `NWConnection` to the target carries
`NWParameters` with `proxyConfigurations = [ProxyConfiguration(socksv5Proxy: upstream)]`
(macOS 14+), so the connection is made BY the SOCKS proxy — i.e. by sshd on the VDS.

**Spike first (gates the transport, not the architecture):** verify on macOS 15 that a dial to
an `NWEndpoint.hostPort(host: "some.blocked.domain", …)` with a `socksv5Proxy` configuration
sends the HOSTNAME to the SOCKS server (SOCKS5 domain address type — sshd then resolves it on
the VDS) rather than resolving it locally. A small harness against a local `ssh -D` is enough.
If it resolves locally, adopt the fallback from the Decisions section.

The bridge runs as a second synthetic daemon: fixed `RemoteProxy.bridgeDaemonID`, the existing
marker command `devdeck:proxy-listen -C <path>` pointing at a separate generated config
(`proxy-bridge.json`, owner-only like `gost.json`), whose JSON is the same generated schema plus
one extension key the gost engine never sees:

```json
{"services":[{"addr":":18888", …}], "upstreamSocks":"127.0.0.1:1080"}
```

`parseBuiltInProxyConfig` returns the optional upstream; the share path is untouched (its config
never contains the key). Supervision, the popover row, the occupied-port machinery and the
session log lines all come from the existing engine for free. Like the share's built-in
listener, the bridge is excluded from the quit dialog's daemon count; the tunnel command is a
real ssh process and keeps today's daemon semantics.

Lifecycle, owned by `ProxyManager` (mirror of the share side): remote proxy selected → write
`proxy-bridge.json`, start the tunnel command and the bridge, hold both (watchdog); deselected →
stop both, remove `proxy-bridge.json`. On app launch with a remote proxy selected, both come up
the way the share does.

## Part 4 — Browser via proxy

A button on the Proxy page (and next to the active proxy in the popover), enabled whenever
`resolvedEndpoint()` resolves — it serves the LAN proxy too, not only the remote one:

```
open -na "Google Chrome" --args
  --proxy-server=<resolved proxy URL>
  --proxy-bypass-list="localhost;127.0.0.1"
  --user-data-dir=<Application Support>/DevDeck/ProxyBrowser
```

A separate instance with its own profile: the system browser and its settings are never
touched, the claude.ai session survives restarts, and the OAuth callback to `localhost` bypasses
the proxy. The argument list is built by a pure function (testable); Chrome missing at
`/Applications/Google Chrome.app` → an explanatory alert, no fallback browsers in v1.

`/login` flow: run `/login` in a flagged `claude` → copy the printed URL into the proxied
window → authenticate → the callback lands on the local port Claude Code listens on.

## Part 5 — UI

- **Proxy page**: a "Remote proxies" group inside the existing list — each row selectable
  exactly like a discovered proxy, plus a "via SSH tunnel" caption and a tunnel-state dot.
  Add/edit sheet: name, ssh destination (only at creation — afterwards the command is the source
  of truth), local port, SOCKS port, linked command (read-only link that reveals the command).
- The check button and exit-IP row work unchanged and show the VDS's public IP.
- **Popover**: the bridge and tunnel appear as daemon rows (they are daemons); the Proxy section
  shows the active remote proxy with the same check affordance as a discovered one.
- L10n: EN/RU for every new string, as usual.

## Part 6 — Testing

Unit (fakes, no network): remote-proxy config round-trip; selection mutual exclusion
(`activeRemoteProxyID` vs `activeProxyName`); resolution — tunnel down / bridge down / both up →
`.unavailable` / `.routed`; `proxy.env` written with `*` and removed on deselect; Chrome
argument builder; `parseBuiltInProxyConfig` with and without `upstreamSocks`; tunnel-command
creation from the form (ports, flags, destination quoting).

Loopback integration (extends the existing listener tests): a local SOCKS5 stub server; the
bridge with `upstream` pointed at it → CONNECT through the bridge arrives at the stub with the
**hostname** (not an IP) in the SOCKS request, and bytes flow end-to-end.

Manual dogfood: the real VDS — select, check button shows the VDS IP, `dp curl api.ipify.org`
agrees, `/login` through the proxied browser completes, flagged `claude` works.

## Out of scope

- Installing anything on the VDS (the deleted first draft; documented as the DNS fallback only).
- Auth or non-loopback endpoints for remote proxies; SOCKS emitted to clients.
- The internal WKWebView browser (follow-up if the Chrome instance annoys).
- Announcing a remote proxy to the LAN (a remote proxy is this Mac's private client-side route).
