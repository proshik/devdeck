import Foundation
import Network

/// A proxy announced on the LAN by another DevDeck. Ephemeral — rebuilt from Bonjour on every
/// browse update and never persisted; only the `name` (the Bonjour identity) is remembered in
/// settings, so the active choice survives the peer's IP changing.
struct DiscoveredProxy: Equatable, Identifiable, Sendable {
    /// Bonjour service name — the stable identity across IP changes and restarts.
    let name: String
    /// LAN IPv4 carried in the TXT record (the peer picks its own en* address).
    let host: String
    let port: Int
    /// The peer requires `user:pass`.
    let authRequired: Bool
    /// The peer's egress IP as seen from the internet — proof the tunnel is actually up. Best-effort.
    let exitIP: String?
    /// Protocols the listener speaks, e.g. "http+socks".
    let proto: String
    /// TXT record schema version.
    let schema: Int
    /// False when this entry was rebuilt from the remembered endpoint rather than heard on the
    /// network. `var` with a default so every existing construction site keeps compiling.
    var isLive: Bool = true

    var id: String { name }
}

/// What the host announces about its listener. The password is NEVER part of this.
struct ProxyAdvertisement: Equatable, Sendable {
    var serviceName: String
    var port: Int
    var authRequired: Bool
    /// LAN IPv4 clients should dial (must be an en* address, never the VPN tunnel — see `pickLANIPv4`).
    var host: String
    /// Egress IP through the VPN, resolved best-effort after the listener comes up.
    var exitIP: String?
}

/// Bonjour service type shared by the browser and the advertiser.
/// Must match `NSBonjourServices` in Info.plist, or macOS silently returns nothing.
let proxyBonjourServiceType = "_devdeck-proxy._tcp"

/// Current TXT schema. Bumped if the key set changes incompatibly.
let proxyTXTSchemaVersion = 1

/// Build the TXT record for an advertisement. Pure — and deliberately without any password key
/// (asserted by a test): only `auth=1` tells clients that credentials are needed.
func proxyTXTRecord(_ ad: ProxyAdvertisement) -> [String: String] {
    var txt = [
        "v": String(proxyTXTSchemaVersion),
        "proto": "http+socks",
        "auth": ad.authRequired ? "1" : "0",
        "host": ad.host,
        "port": String(ad.port),
    ]
    if let exitIP = ad.exitIP, !exitIP.isEmpty { txt["vpnip"] = exitIP }
    return txt
}

/// Parse a browse result's TXT record into a `DiscoveredProxy`. Pure.
/// Returns nil when the record lacks a usable endpoint — both sides are ours, so in the MVP the
/// TXT carries host/port directly and no per-result `NWConnection` resolution is needed.
func parseProxyTXT(name: String, txt: [String: String]) -> DiscoveredProxy? {
    guard let host = txt["host"], !host.isEmpty,
          let port = txt["port"].flatMap(Int.init), port > 0 else { return nil }
    return DiscoveredProxy(
        name: name,
        host: host,
        port: port,
        authRequired: txt["auth"] == "1",
        exitIP: txt["vpnip"].flatMap { $0.isEmpty ? nil : $0 },
        proto: txt["proto"] ?? "http+socks",
        schema: txt["v"].flatMap(Int.init) ?? proxyTXTSchemaVersion
    )
}

// MARK: - Probe

/// Browses the LAN for announced proxies. Behind a protocol so `ProxyManager` is tested with a
/// fake that emits result sets on demand — no real network, no Bonjour, no timing.
///
/// `results()` is push-based: one long-lived stream that yields the FULL current set on every
/// change (no polling loop). Cancelling the stream stops the browser.
protocol ProxyDiscovering: Sendable {
    func results() -> AsyncStream<[DiscoveredProxy]>
    func stop()
}

/// The real browser: `NWBrowser` over `_devdeck-proxy._tcp`, reading endpoints straight from TXT.
///
/// Requires `NSLocalNetworkUsageDescription` + `NSBonjourServices` in Info.plist — without them
/// macOS 15 silently returns an empty result set instead of prompting.
final class LiveProxyDiscovery: ProxyDiscovering, @unchecked Sendable {
    private let lock = NSLock()
    private var browser: NWBrowser?

    func results() -> AsyncStream<[DiscoveredProxy]> {
        AsyncStream { continuation in
            let browser = NWBrowser(
                for: .bonjourWithTXTRecord(type: proxyBonjourServiceType, domain: nil),
                using: .tcp
            )
            browser.browseResultsChangedHandler = { results, _ in
                continuation.yield(Self.proxies(from: results))
            }
            browser.stateUpdateHandler = { state in
                switch state {
                case .failed(let error):
                    DiagnosticLog.shared.log("Proxy discovery failed: \(error.localizedDescription)", level: .warn)
                    continuation.finish()
                case .cancelled:
                    continuation.finish()
                case .ready:
                    DiagnosticLog.shared.log("Proxy discovery browsing \(proxyBonjourServiceType)")
                default:
                    break
                }
            }
            lock.lock()
            self.browser?.cancel()
            self.browser = browser
            lock.unlock()
            continuation.onTermination = { [weak self] _ in self?.stop() }
            browser.start(queue: .main)
        }
    }

    func stop() {
        lock.lock()
        let current = browser
        browser = nil
        lock.unlock()
        current?.cancel()
    }

    /// Map a browse result set to proxies, dropping anything without a parseable TXT endpoint.
    private static func proxies(from results: Set<NWBrowser.Result>) -> [DiscoveredProxy] {
        results.compactMap { result -> DiscoveredProxy? in
            guard case .service(let name, _, _, _) = result.endpoint,
                  case .bonjour(let txt) = result.metadata else { return nil }
            return parseProxyTXT(name: name, txt: txt.dictionary)
        }
        .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
