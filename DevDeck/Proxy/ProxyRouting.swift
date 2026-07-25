import Foundation

/// Verdict for a command flagged `routeThroughProxy`, resolved once per launch.
///
/// `unavailable` is deliberately NOT a silent fallback to a direct connection: the whole point of
/// the flag is that the tool must egress through the VPN, so a missing proxy fails the run loudly.
enum ProxyRouting: Equatable {
    /// The command isn't flagged — launch it untouched.
    case notRouted
    /// Proxy resolved — merge this env over the command's own.
    case routed(env: [String: String])
    /// Flagged, but there is no usable proxy (none active, not discovered, or auth without credentials).
    case unavailable
}

/// Hosts that must never go through the proxy (loopback services on this machine).
let proxyNoProxyList = "localhost,127.0.0.1,::1"

/// The proxy URL. Extracted so the injected environment and the terminal helper's `proxy.env` are
/// built from ONE place — escaping drifting between them would be invisible until it broke.
func proxyURL(host: String, port: Int, user: String?, pass: String?) -> String {
    let auth = user.flatMap { $0.isEmpty ? nil : $0 }
        .map { "\(urlEscapeProxyCredential($0)):\(urlEscapeProxyCredential(pass ?? ""))@" } ?? ""
    return "http://\(auth)\(host):\(port)"
}

/// Build the proxy environment injected into a routed command.
///
/// Both cases are emitted: `HTTPS_PROXY`/`HTTP_PROXY`/`ALL_PROXY` and their lowercase twins —
/// curl and many Go/Node CLIs read only one of the two, and which one is not predictable.
/// `gost -L auto://` speaks HTTP CONNECT on the same port, so an `http://` URL covers HTTPS too.
func proxyEnv(host: String, port: Int, user: String?, pass: String?) -> [String: String] {
    let url = proxyURL(host: host, port: port, user: user, pass: pass)
    return [
        "HTTPS_PROXY": url, "HTTP_PROXY": url, "ALL_PROXY": url,
        "https_proxy": url, "http_proxy": url, "all_proxy": url,
        "NO_PROXY": proxyNoProxyList, "no_proxy": proxyNoProxyList,
    ]
}

/// Percent-escape a username/password for the `user:pass@host` userinfo slot, so a password
/// containing `@`, `:` or `/` doesn't break the URL apart.
func urlEscapeProxyCredential(_ value: String) -> String {
    var allowed = CharacterSet.alphanumerics
    allowed.insert(charactersIn: "-._~")   // RFC 3986 unreserved
    return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
}
