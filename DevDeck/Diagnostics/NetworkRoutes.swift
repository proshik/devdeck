import Foundation
import SystemConfiguration

struct NetworkRoutes: Equatable, Sendable {
    var ipv4: String?
    var ipv6: String?
}
protocol NetworkRouteProbing: Sendable {
    func sample() -> NetworkRoutes
}
/// Public SystemConfiguration primary routes, read together to avoid mixed snapshots.
struct LiveNetworkRouteProbe: NetworkRouteProbing {
    func sample() -> NetworkRoutes {
        let ipv4 = SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv4)
        let ipv6 = SCDynamicStoreKeyCreateNetworkGlobalEntity(nil, kSCDynamicStoreDomainState, kSCEntNetIPv6)
        guard let store = SCDynamicStoreCreate(nil, "DevDeck network routes" as CFString, nil, nil),
              let values = SCDynamicStoreCopyMultiple(store, [ipv4, ipv6] as CFArray, nil) as? [String: [String: Any]] else { return .init() }
        return .init(ipv4: values[ipv4 as String]?[kSCDynamicStorePropNetPrimaryInterface as String] as? String,
                     ipv6: values[ipv6 as String]?[kSCDynamicStorePropNetPrimaryInterface as String] as? String)
    }
}
