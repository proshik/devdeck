import Foundation
@testable import DevDeck

/// Records what was announced instead of publishing it — verifies the advertise/withdraw
/// lifecycle and the TXT contents without real mDNS traffic.
@MainActor
final class FakeProxyAdvertising: ProxyAdvertising {
    /// Every advertisement in order (a watchdog restart produces a second entry).
    private(set) var advertised: [ProxyAdvertisement] = []
    /// The last advertisement pushed through `advertise` or `updateTXT`.
    private(set) var lastTXT: ProxyAdvertisement?
    private(set) var stopCount = 0

    func advertise(_ ad: ProxyAdvertisement) {
        advertised.append(ad)
        lastTXT = ad
    }

    func updateTXT(_ ad: ProxyAdvertisement) {
        lastTXT = ad
    }

    func stop() {
        stopCount += 1
    }
}
