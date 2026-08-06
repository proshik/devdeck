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
    // Cheap discriminator before the JSON deserialization: on a busy listener the majority of
    // lines are ` <-> ` / ` >-< ` destination dials, which get thrown away below anyway. Skipping
    // straight past those means `JSONSerialization` never runs on the hot path, and — for this
    // feature specifically — a dial's `host`/`dst` (somebody else's browsing history) is never even
    // materialized into memory, not just left unread.
    guard line.contains(" >< ") || line.contains(" <> ") else { return nil }
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
