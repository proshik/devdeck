# Design: Terminal Helper + Per-Run Directory Prompt

> Date: 2026-07-26. Status: designed, ready to implement.
> Builds on the Proxy Manager (0.5.0) and the remembered endpoint (0.5.1) —
> `docs/superpowers/specs/2026-07-25-proxy-remembered-endpoint-design.md`.

## Problem

Running `claude` through the LAN proxy in a new directory currently costs a round trip through the
UI: create a DevDeck command, set its working directory, tick "Route through the LAN proxy", save,
run. That is once per directory, forever, for a tool whose whole point is that it follows you
between projects.

Two shapes of the same request, and the user wants both:

- **From a terminal already sitting in the right directory** — nothing should need creating.
- **From the deck, without a terminal open** — one command, pick the directory at launch.

## Goal

Route an arbitrary command through the active proxy from any directory, without creating a
per-directory DevDeck command, and without re-introducing the "copy the IP by hand" problem the
Proxy Manager exists to remove.

## Decisions

| Question | Decision |
|---|---|
| Entry points | Both: terminal wrapper **and** in-app directory prompt |
| Wrapper's source of truth | `~/.config/devdeck/proxy.env`, maintained by DevDeck |
| Wrapper scope | Generic — `dp <command> [args…]`, not `claude`-specific |
| Wrapper installation | User pastes a shell function into `.zshrc`; the Proxy page shows it with a Copy button |
| Directory prompt | One-shot per run; `config.json` is never modified |
| Stale/foreign-network protection | The wrapper verifies the LAN itself, so it holds even when DevDeck is not running |

## Part 1 — Terminal helper

### The file

`~/.config/devdeck/proxy.env`, mode **0600**:

```
# Written by DevDeck — do not edit, regenerated when the active proxy changes.
DEVDECK_PROXY_URL=http://192.168.31.117:9999
DEVDECK_PROXY_LAN=192.168.31
```

Plain `KEY=value`, deliberately **not** `export` lines: the shell function reads the two keys it
wants instead of `source`-ing the file, so a corrupted or tampered file cannot execute anything.

`DEVDECK_PROXY_LAN` is the /24 prefix of the machine's current `lanIP()` at write time — the same
`lanPrefix(of:)` helper the remembered endpoint already uses.

### Who writes it

`ProxyManager`, from one private method called wherever `refreshCredentialCache()` is already
called (start, discovery updates, `setActiveProxy`, `setClientCredentials`) plus `stopDiscovery`.

The verdict comes from the **same resolver `routing(for:)` uses** — extract a private
`resolvedEndpoint() -> (proxy: DiscoveredProxy, user: String?, pass: String?)?` so the file and the
in-app injection can never disagree about whether a proxy is usable. Extract `proxyURL(host:port:user:pass:)`
out of `proxyEnv(…)` so both build the URL from one place.

The file is **deleted** whenever that resolver returns nil (no active proxy, discovery off,
credentials missing, LAN mismatch) or when `lanIP()` is nil. A missing file is the safe state: the
wrapper refuses to run.

Filesystem access sits behind a protocol, following the probe pattern used everywhere else in
`DevDeck/Proxy/` — so tests never touch the real `~/.config`:

```swift
protocol ProxyEnvFileWriting: Sendable {
    func write(_ contents: String)   // creates the directory, mode 0600, atomic
    func remove()
}
```

`LiveProxyEnvFile` targets `~/.config/devdeck/proxy.env`; `FakeProxyEnvFile` records the last
contents and the remove count. `ProxyManager` takes it as an injected dependency alongside
`discovering`/`advertiser`/`credentials`, and the pure text builder
`proxyEnvFileContents(url:lanPrefix:)` lives next to them in `ProxyEnvFile.swift`.

Consequence worth stating: if the app somehow routes while `lanIP()` is nil, the file is still
deleted and the terminal path refuses. The two paths differ only in the fail-safe direction.

### The shell function

Shown on the Proxy page with a Copy button; the user pastes it into `.zshrc` once.

```zsh
dp() {
  local f=$HOME/.config/devdeck/proxy.env url lan ip iface
  [[ -r $f ]] || { print -u2 "dp: DevDeck has no active proxy"; return 1; }
  url=$(sed -n 's/^DEVDECK_PROXY_URL=//p' $f)
  lan=$(sed -n 's/^DEVDECK_PROXY_LAN=//p' $f)
  [[ -n $url && -n $lan ]] || { print -u2 "dp: proxy.env is incomplete"; return 1; }
  for iface in ${(f)"$(ifconfig -l | tr ' ' '\n')"}; do
    [[ $iface == en* ]] && ip=$(ipconfig getifaddr $iface 2>/dev/null) && [[ -n $ip ]] && break
  done
  [[ -n $ip && ${ip%.*} == $lan ]] || { print -u2 "dp: proxy $lan is not on this network"; return 1; }
  HTTPS_PROXY=$url HTTP_PROXY=$url ALL_PROXY=$url \
  https_proxy=$url http_proxy=$url all_proxy=$url \
  NO_PROXY=localhost,127.0.0.1,::1 no_proxy=localhost,127.0.0.1,::1 "$@"
}
```

**The interface scan must not come from the default route.** With a full-tunnel corporate VPN the
default route points at `utun*`, whose address `ipconfig getifaddr` does not report — the check
would fail in exactly the scenario this whole feature line exists to serve. Scanning `en*` mirrors
`pickLANIPv4` and is the only correct source here.

The env assignments are a command prefix, so they apply to that process only and never leak into
the calling shell — the same containment the in-app injection gives.

The snippet stays **English-only**. It is code the user pastes into their shell, not app UI; the
section title, hint and button around it go through `L10n` with EN and RU as usual.

It is rendered in a monospaced, selectable block with a Copy button that writes to
`NSPasteboard.general` (`clearContents()` then `setString(_:forType:.string)`) and flips its label
to "Copied" briefly. The file path is shown next to it, so the connection between the two is
visible without reading the docs.

## Part 2 — Per-run directory prompt

`Command` gains `promptForDirectory: Bool` (`decodeIfPresent ?? false`, memberwise default, in
`CodingKeys`).

The prompt is AppKit and therefore lives in the **view layer**, not `ProcessManager`: pressing Run
on such a command opens an `NSOpenPanel`, and on OK the popover runs a **copy** of the command with
`workingDirectory` set to the chosen path. Nothing is persisted. `ProcessManager` stays headless
and testable.

The substitution itself is a pure method on the model, in `Models/Command.swift` — not in the view,
so it can be tested without AppKit:

```swift
/// A copy bound to a directory chosen at launch time. Returns self unchanged for nil,
/// so the caller doesn't branch. Never persisted — the stored command keeps its own value.
func withWorkingDirectory(_ path: String?) -> Command
```

`NSApp.activate()` before presenting the panel — the popover is `.transient` and dismisses when
focus moves, so without it the panel can open behind other windows.

**Chains are out of scope.** A chain step runs through `ProcessManager` with no UI, so a step
carrying this flag uses its own `workingDirectory` as today. The flag is documented in the editor
as applying to direct runs from the deck.

## Security trade-off — stated deliberately

When the active proxy requires authentication, `DEVDECK_PROXY_URL` contains `user:pass`, so **the
proxy password lands on disk in plaintext**. This weakens the Proxy Manager's original rule that
the password lives only in the Keychain.

It is accepted knowingly: a terminal helper cannot read the Keychain without prompting, and the
alternative — omitting credentials — would make the terminal path unusable with an authenticated
proxy. Mitigations: mode 0600, a directory under `~/.config`, and the LAN check that keeps the file
from being used on a foreign network. Anyone who can read the file can already read the user's
shell history and SSH keys.

The in-app path is unchanged: it still reads the password from the Keychain and never writes it to
`config.json`.

## Rejected

- **`source`-ing proxy.env** — turns a data file into a code-execution surface for no benefit.
- **Installing a script into `~/.local/bin`** — puts the app in the business of writing outside its
  own directories and needs that path on `PATH` anyway.
- **A `claude`-specific wrapper** — a subset of the generic one with no saving; `alias cl='dp claude'`.
- **Remembering the prompted directory** — the request was explicitly to stop maintaining
  per-directory state.
- **Deriving the interface from `route -n get default`** — breaks under a full-tunnel VPN (above).

## Testing

Pure and injectable, per the existing probe pattern:

- `proxyEnvFileContents(url:lanPrefix:)` — exact text, including the do-not-edit header.
- `Command.withWorkingDirectory(_:)` — directory applied; nil returns an equal command; every other
  field survives; the receiver is unchanged.
- `ProxyManager` with `FakeProxyEnvFile`: written when the endpoint resolves; removed when it does
  not; removed on `stopDiscovery`; carries the credentials when auth is on; carries the prefix of
  the injected `lanIP()`.
- Config: `promptForDirectory` round-trip and resilient default.

**The shell function's two refusal paths are tested for real** — write a temp `proxy.env`, run the
function under `/bin/zsh` via `Process`, and assert a non-zero exit and no proxy variables when
(a) the file is missing and (b) `DEVDECK_PROXY_LAN` is a prefix that cannot match (`203.0.113`,
TEST-NET-3). These are the security-relevant branches and they are deterministic.

The success path is **manual verification**: it depends on the machine's live network, so asserting
it in a unit test would only re-implement the scan and prove nothing. Verify by hand:
`dp curl -s https://api.ipify.org` returns the VPN egress IP.

## Files

**Create:** `DevDeck/Proxy/ProxyEnvFile.swift` (contents builder, `ProxyEnvFileWriting` +
`LiveProxyEnvFile`), `DevDeck/Proxy/ProxyShellHelper.swift` (the snippet text),
`DevDeckTests/Support/FakeProxyEnvFile.swift`, `DevDeckTests/ProxyEnvFileTests.swift`,
`DevDeckTests/ProxyShellHelperTests.swift`.

**Change:** `Models/Command.swift` (+`promptForDirectory`, `withWorkingDirectory(_:)`);
`Proxy/ProxyRouting.swift` (extract `proxyURL(host:port:user:pass:)`); `Proxy/ProxyManager.swift`
(shared `resolvedEndpoint()`, env-file refresh, new injected dependency);
`MenuBar/PopoverView.swift` (`NSOpenPanel` on run); `MainWindow/CommandEditorView.swift`
(toggle + hint); `MainWindow/ProxyShareEditorView.swift` (snippet + Copy);
`Localization/L10n.swift`; `CHANGELOG.md`.
