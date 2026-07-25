# Design: Remembered Proxy Endpoint (discovery resilience)

> Date: 2026-07-25. Status: designed, ready to implement.
> Follows the Proxy Manager feature shipped in 0.5.0 (`docs/proxy-manager-plan.md`).

## Problem

`ProxyManager.activeProxy` resolves the active choice only against `discovered`, which is live
Bonjour state. When mDNS stops arriving, the active proxy silently becomes `nil`,
`routing(for:)` returns `.unavailable`, and every command flagged `routeThroughProxy` fails —
even when the proxy itself is perfectly reachable.

This is not hypothetical: it is the normal state of the work Mac whenever its corporate VPN is up.

## Facts (verified live on the work Mac, 2026-07-25, corporate VPN connected)

Sharing Mac: `macbook-pro-prokhor`, `192.168.31.117:9999`, VPN egress `78.40.193.132`.

| Check | Result | Meaning |
|---|---|---|
| `route -n get 192.168.31.117` | `interface: en0` | the VPN did NOT capture the LAN subnet |
| `nc -vz 192.168.31.117 9999` | `succeeded!` | unicast TCP to the proxy works |
| `dns-sd -B _devdeck-proxy._tcp` | no `Add` lines at all | multicast (224.0.0.251) is filtered |
| `curl --proxy http://192.168.31.117:9999 https://api.ipify.org` | `78.40.193.132` | the proxy really egresses through the VPN |

So the corporate VPN blocks **discovery only**. The transport is fine and the feature is fully
usable — DevDeck just loses the address.

## Goal

Keep a flagged command working whenever the proxy is reachable, without reintroducing the
manual IP-copying this feature exists to eliminate.

## Design

### Data model — `Models/Config.swift`

Three fields added to `Settings`, flat like every other field there, each decoded with
`decodeIfPresent ?? default`:

```swift
var activeProxyHost: String?        // last known address of the active proxy
var activeProxyPort: Int?
var activeProxyAuthRequired: Bool   // caching this keeps the credential check honest
```

`activeProxyAuthRequired` is not optional polish: without it, a remembered auth-protected proxy
would resolve as open and skip the credentials requirement.

This is **one endpoint belonging to the current active choice**, not a per-peer table: selecting a
different proxy overwrites it. A table would be dead weight — only the active proxy is ever routed to.

`exitIP` is deliberately NOT cached — it is cosmetic and only meaningful while the peer is live.

**No schema bump.** The added keys are optional and the decode is resilient key-by-key; the
1 → 2 bump was needed for the new `proxy` block, not for additive settings.

### Writing the cache — `Proxy/ProxyManager.swift`

One new `CommandStore` mutator — `rememberActiveProxyEndpoint(host:port:authRequired:)` — called
from exactly two places, and writing **only when the value actually changed** (mirroring the
existing `guard ... != ...` pattern in the other mutators). Without that guard every Bonjour browse
update would rewrite `config.json` on disk.

1. the discovery loop, right after `discovered` is replaced — if the active proxy is in the fresh
   result set, refresh the cache from it;
2. `setActiveProxy(_:)` — persist the endpoint at the moment of selection.

`setActiveProxy(nil)` clears the cached endpoint along with the name and username.

**The cache is never written from `activeProxy`.** It is a computed property that SwiftUI evaluates
during `body`; refreshing from its getter would write `config.json` on every render. Reads stay pure,
writes happen only at the two points above.

### Reading the cache

`activeProxy` becomes three-step, and stays a pure read:

1. the active name is in `discovered` → return the live entry (authoritative);
2. otherwise `activeProxyHost` + `activeProxyPort` are set → synthesize a `DiscoveredProxy` from them
   (`isLive: false`);
3. otherwise `nil` → `.unavailable`, exactly as today.

`DiscoveredProxy` gains `isLive: Bool` so the UI can tell a live announcement from a remembered one.

### UI

Today a proxy that stops announcing simply vanishes from the list, leaving an empty panel and no
explanation — which is precisely how this problem presented itself. So the active proxy is shown
**always**, including when it is not currently heard: the row stays, its status dot is dimmed, and
a caption reads "Last known address". Applies to both the popover section and the Proxy page.

One new L10n entry (EN/RU).

### Security

A deliberate, stated trade-off: Bonjour announcements are **already** unauthenticated — any machine
on the LAN can claim to be a DevDeck proxy. **On the same LAN** a remembered address is therefore no
weaker than a live announcement: if DHCP has reassigned it, the connection either fails outright or
reaches a stranger's port 9999, exactly as a hostile live announcement would. The mitigation is
unchanged and already available: enable the password.

Across networks the equivalence breaks, and the original wording claiming otherwise was wrong. The
cache outlives the Wi-Fi it was learned on, so on the next network `192.168.31.117:9999` addresses
whatever machine holds that address *there* — and because `activeProxyAuthRequired` is cached too,
`routing(for:)` would send it `Proxy-Authorization: Basic …`, leaking the proxy password to a third
party with no attacker action at all. The cache is therefore **LAN-scoped**: `activeProxyLANPrefix`
records the /24 of this machine's own address when the endpoint was learned, and the fallback
resolves only while the current LAN IPv4 has the same prefix. A different network, or no LAN address
at all, means no remembered proxy (the flagged command fails, which is the safe direction). /24 is a
heuristic, not proof of identity — two networks can reuse a subnet — but it removes the
no-interaction case and costs at most one rediscovery.

The protective invariant is preserved: with neither a live nor a remembered endpoint, a flagged
command still **fails loudly** rather than connecting directly and leaking past the VPN.

### Rejected

- **Manual `host:port` entry.** Covers only the case where the sharing Mac's IP changes while
  discovery is blocked, which is repaired without any code: drop the corporate VPN for ten seconds,
  let it rediscover, reconnect. Roughly doubles the model/UI/test surface for that one case.
- **Cache expiry (don't use an endpoint older than N days).** A stale address simply fails to
  connect; a timer would only add behaviour that is hard to predict from the UI.
- **Falling back to a direct connection when no proxy resolves.** Explicitly out of the question —
  it is the exact leak the `routeThroughProxy` flag exists to prevent.

## Testing

With the existing fakes (`FakeProxyDiscovering`, `FakeProxyAdvertising`, `FakeProxyCredentialStore`),
no real network:

- the cache is used when the peer is not in the current result set;
- a live announcement wins over the cache and refreshes it;
- the cache is written on selection and on discovery updates, and only when the value changed
  (a repeated identical browse update must not persist anything);
- reading `activeProxy` never writes — repeated reads leave `config.json` untouched;
- `routing(for:)` returns `.routed` built from a cached endpoint;
- a cached auth-protected proxy without stored credentials still resolves to `.unavailable`;
- clearing the active proxy clears the cache;
- config round-trip of the new fields, and resilient decode of a file that lacks them.

## Files

**Change:** `Models/Config.swift` (3 fields), `Proxy/ProxyDiscovery.swift` (`isLive`),
`Proxy/ProxyManager.swift` (cache read/write), `Store/CommandStore.swift` (persist the endpoint),
`MenuBar/ProxySectionView.swift`, `MainWindow/ProxyShareEditorView.swift`, `Localization/L10n.swift`.

**Tests:** extend `ProxyManagerDiscoveryTests`, `ProxyManagerRoutingResolutionTests`,
`ProxyConfigCodecTests`.
