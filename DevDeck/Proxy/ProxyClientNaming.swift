import Foundation

/// Resolves a peer's IP to something a human recognizes. Behind a protocol (the probe pattern used
/// everywhere in this subsystem) so the monitor is unit-tested without mDNS.
protocol ProxyClientNaming: Sendable {
    /// nil when the address has no name — the caller shows the bare IP, which is never worse.
    func hostname(for ip: String) async -> String?
}

/// Reverse lookup through the system resolver.
///
/// No `dns-sd` subprocess is needed: macOS answers `.local` reverse queries out of mDNSResponder,
/// so a Mac on the same LAN resolves with no DNS server involved.
struct ReverseDNSClientNaming: ProxyClientNaming {
    func hostname(for ip: String) async -> String? {
        // getnameinfo blocks for as long as the resolver takes — never on the main thread.
        await Task.detached(priority: .utility) { reverseLookup(ip) }.value
    }
}

/// Blocking reverse lookup. The caller MUST keep it off the main thread.
///
/// IPv4 only: the share is announced over an IPv4 address (`pickLANIPv4`), so a peer arriving over
/// IPv6 is an oddity — it gets nil here and is shown by its address.
func reverseLookup(_ ip: String) -> String? {
    var addr = sockaddr_in()
    addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    addr.sin_family = sa_family_t(AF_INET)
    guard ip.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else { return nil }

    var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
    let status = withUnsafePointer(to: &addr) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
            getnameinfo(sa, socklen_t(MemoryLayout<sockaddr_in>.size),
                        &host, socklen_t(NI_MAXHOST), nil, 0, NI_NAMEREQD)
        }
    }
    guard status == 0 else { return nil }   // NI_NAMEREQD → an unnamed address is an error, not a digit string
    let name = shortHostName(String(cString: host))
    return name.isEmpty ? nil : name
}

/// Trim the resolver's trailing dot and the `.local` Bonjour suffix — the same shortening
/// `ProxyShare.defaultServiceName` applies to this machine's own host name.
func shortHostName(_ raw: String) -> String {
    var name = raw
    if name.hasSuffix(".") { name = String(name.dropLast()) }
    if name.hasSuffix(".local") { name = String(name.dropLast(6)) }
    return name
}
