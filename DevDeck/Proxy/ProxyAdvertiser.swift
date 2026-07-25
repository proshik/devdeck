import Foundation
import Darwin

/// One interface's IPv4 address, as read from `getifaddrs`.
struct NetworkInterfaceAddress: Equatable, Sendable {
    let name: String
    let address: String
}

/// Pick the LAN IPv4 to announce. **Pure — this is the correctness-critical bit of the feature.**
///
/// The sharing Mac holds a full-tunnel VPN, so it also owns `utun*` addresses. Announcing one of
/// those would publish an address no peer on the Wi-Fi can reach, and discovery would look like it
/// works while every connection times out. Only physical `en*` interfaces (Wi-Fi / Ethernet) are
/// eligible; `utun*` (VPN), `lo0` (loopback), `awdl*`/`llw*` (AirDrop peer-to-peer) and `bridge*`
/// are excluded by construction, as are self-assigned link-local addresses.
///
/// Ties are broken in natural interface order (en0 before en1 before en10) — the built-in
/// Wi-Fi/Ethernet port, which is the LAN the peers are actually on.
func pickLANIPv4(from interfaces: [NetworkInterfaceAddress]) -> String? {
    interfaces
        .filter { $0.name.hasPrefix("en") }
        .filter { !$0.address.hasPrefix("169.254.") && !$0.address.hasPrefix("127.") }
        .min { $0.name.localizedStandardCompare($1.name) == .orderedAscending }?
        .address
}

/// Reduce an IPv4 address to its /24 prefix — a cheap identity for "the LAN this address is on".
/// Pure. nil for anything that isn't a dotted quad (an IPv6 address, a hostname, hand-edited junk).
///
/// Used to scope the remembered proxy endpoint: `192.168.31.117` means a completely different
/// machine on a different Wi-Fi, so a cached address must not be dialled — with credentials
/// attached — after the laptop has moved networks. /24 is an assumption, not a fact (a /16 home
/// network exists), but erring toward "different LAN" only ever costs a rediscovery.
func lanPrefix(of address: String) -> String? {
    let octets = address.split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4, octets.allSatisfy({ UInt8($0) != nil }) else { return nil }
    return octets.prefix(3).joined(separator: ".")
}

/// Every up, non-loopback interface carrying an IPv4 address.
func activeIPv4Interfaces() -> [NetworkInterfaceAddress] {
    var head: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&head) == 0, let first = head else { return [] }
    defer { freeifaddrs(head) }

    var result: [NetworkInterfaceAddress] = []
    for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let flags = Int32(pointer.pointee.ifa_flags)
        guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
        guard let addr = pointer.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                          &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
        result.append(NetworkInterfaceAddress(name: String(cString: pointer.pointee.ifa_name),
                                              address: String(cString: host)))
    }
    return result
}

/// This machine's announceable LAN IPv4, or nil when it isn't on a LAN.
func currentLANIPv4() -> String? { pickLANIPv4(from: activeIPv4Interfaces()) }

// MARK: - Probe

/// Publishes the running listener on Bonjour. Behind a protocol so `ProxyManager` is tested with a
/// fake that records what was advertised — no real mDNS traffic.
///
/// `@MainActor` (like `Notifier`): the live implementation drives `NetService`, which needs a run loop.
@MainActor
protocol ProxyAdvertising {
    func advertise(_ ad: ProxyAdvertisement)
    /// Refresh the TXT record in place (used when the exit IP resolves after publishing).
    func updateTXT(_ ad: ProxyAdvertisement)
    func stop()
}

/// The real advertiser — `NetService` in **publish-only** mode.
///
/// Deliberately NOT `NWListener`: that would bind a socket of its own, whereas the port we announce
/// is already held by `gost`. `NetService` publishes a record pointing at an existing port without
/// touching it.
@MainActor
final class LiveProxyAdvertiser: NSObject, ProxyAdvertising, NetServiceDelegate {
    private var service: NetService?

    nonisolated override init() { super.init() }

    func advertise(_ ad: ProxyAdvertisement) {
        stop()
        let service = NetService(domain: "local.", type: proxyBonjourServiceType,
                                 name: ad.serviceName, port: Int32(ad.port))
        service.delegate = self
        _ = service.setTXTRecord(NetService.data(fromTXTRecord: txtData(ad)))
        self.service = service
        service.publish()
        DiagnosticLog.shared.log(
            "Proxy advertising “\(ad.serviceName)” at \(ad.host):\(ad.port) (auth \(ad.authRequired ? "on" : "off"))")
    }

    func updateTXT(_ ad: ProxyAdvertisement) {
        _ = service?.setTXTRecord(NetService.data(fromTXTRecord: txtData(ad)))
    }

    func stop() {
        guard let service else { return }
        service.stop()
        self.service = nil
        DiagnosticLog.shared.log("Proxy advertising stopped")
    }

    private func txtData(_ ad: ProxyAdvertisement) -> [String: Data] {
        proxyTXTRecord(ad).mapValues { Data($0.utf8) }
    }

    // MARK: - NetServiceDelegate

    nonisolated func netService(_ sender: NetService, didNotPublish errorDict: [String: NSNumber]) {
        let code = errorDict[NetService.errorCode]?.intValue ?? 0
        DiagnosticLog.shared.log("Proxy advertising failed to publish (error \(code)) — "
            + "is Local Network access allowed for DevDeck?", level: .warn)
    }
}
