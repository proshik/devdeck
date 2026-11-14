import Foundation
import Darwin
import SystemConfiguration

struct NetworkInterfaceSample: Equatable, Sendable, Identifiable {
    var id: String
    var name: String
    var received: UInt64
    var sent: UInt64
}
protocol NetworkInterfaceProbing: Sendable {
    func sample() -> [NetworkInterfaceSample]?
}
struct LiveNetworkInterfaceProbe: NetworkInterfaceProbing {
    func sample() -> [NetworkInterfaceSample]? {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, 0, NET_RT_IFLIST2, 0]
        var size = 0
        guard sysctl(&mib, UInt32(mib.count), nil, &size, nil, 0) == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, UInt32(mib.count), &bytes, &size, nil, 0) == 0 else { return nil }
        let names = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] ?? []).reduce(into: [String: String]()) { names, interface in
            if let bsd = SCNetworkInterfaceGetBSDName(interface) as String? {
                names[bsd] = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            }
        }
        var result: [NetworkInterfaceSample] = []
        bytes.withUnsafeBytes { buffer in
            var offset = 0
            while offset + MemoryLayout<if_msghdr>.size <= size {
                let header = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr.self)
                let length = Int(header.ifm_msglen)
                guard length > 0, offset + length <= size else { break }
                defer { offset += length }
                guard header.ifm_type == RTM_IFINFO2, length >= MemoryLayout<if_msghdr2>.size else { continue }
                let info = buffer.loadUnaligned(fromByteOffset: offset, as: if_msghdr2.self)
                guard info.ifm_flags & IFF_UP != 0, info.ifm_flags & IFF_LOOPBACK == 0 else { continue }
                var name = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                guard if_indextoname(UInt32(info.ifm_index), &name) != nil else { continue }
                let id = String(cString: name)
                result.append(.init(id: id, name: names[id].map { "\($0) (\(id))" } ?? id,
                                    received: info.ifm_data.ifi_ibytes, sent: info.ifm_data.ifi_obytes))
            }
        }
        return result.sorted { $0.id < $1.id }
    }
}
struct NetworkTrafficPoint: Identifiable, Sendable {
    var id = UUID()
    var date: Date
    var received: Double
    var sent: Double
}
struct NetworkTrafficAccumulator {
    private var previous: (NetworkInterfaceSample, TimeInterval)?
    private var interface: String?
    var received: UInt64 = 0
    var sent: UInt64 = 0
    mutating func resetInterval() { previous = nil }
    mutating func select(_ id: String?) {
        guard interface != id else { return }
        interface = id; previous = nil; received = 0; sent = 0
    }
    mutating func consume(_ sample: NetworkInterfaceSample?, uptime: TimeInterval, date: Date) -> NetworkTrafficPoint? {
        guard let sample else { previous = nil; return nil }
        defer { previous = (sample, uptime) }
        guard let (old, time) = previous, old.id == sample.id, uptime > time,
              sample.received >= old.received, sample.sent >= old.sent else { return nil }
        let input = sample.received - old.received, output = sample.sent - old.sent
        received &+= input; sent &+= output
        return .init(date: date, received: Double(input) / (uptime - time), sent: Double(output) / (uptime - time))
    }
}
