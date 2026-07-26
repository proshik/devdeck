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
