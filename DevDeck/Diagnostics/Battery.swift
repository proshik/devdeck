import Foundation
import IOKit.ps

/// The internal battery as the menu bar shows it: charge, whether the Mac runs off it, and the
/// system's own time-remaining estimate.
struct BatteryState: Equatable, Sendable {
    let percent: Int
    let isCharging: Bool
    let onBattery: Bool
    /// macOS' estimate; nil while it is still computing one and whenever the Mac is on AC.
    let minutesRemaining: Int?

    /// "64% · 2 h 10 min" on battery, "87% · charging", "100% · on AC".
    func format() -> String {
        let charge = "\(percent)%"
        if onBattery {
            guard let minutesRemaining else { return charge }
            return charge + " · " + L10n.batteryTimeLeft(hours: minutesRemaining / 60,
                                                         minutes: minutesRemaining % 60)
        }
        return charge + " · " + (isCharging ? L10n.batteryCharging : L10n.batteryOnAC)
    }
}

protocol BatteryProbing: Sendable {
    /// nil when the Mac has no internal battery.
    func state() -> BatteryState?
}

struct LiveBatteryProbe: BatteryProbing {
    func state() -> BatteryState? {
        let info = IOPSCopyPowerSourcesInfo().takeRetainedValue()
        let sources = IOPSCopyPowerSourcesList(info).takeRetainedValue() as NSArray as [AnyObject]
        for source in sources {
            guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = d[kIOPSCurrentCapacityKey] as? Int,
                  let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { continue }
            let onBattery = d[kIOPSPowerSourceStateKey] as? String == kIOPSBatteryPowerValue
            let timeToEmpty = d[kIOPSTimeToEmptyKey] as? Int ?? -1
            return BatteryState(percent: Int((Double(current) / Double(max) * 100).rounded()),
                                isCharging: d[kIOPSIsChargingKey] as? Bool ?? false,
                                onBattery: onBattery,
                                minutesRemaining: onBattery && timeToEmpty > 0 ? timeToEmpty : nil)
        }
        return nil
    }
}

/// Calls back on the main run loop whenever the power source changes (plugged / unplugged).
@MainActor
protocol PowerSourceObserving: AnyObject {
    func start(_ onChange: @escaping @MainActor () -> Void)
}

@MainActor
final class LivePowerSourceObserver: PowerSourceObserving {
    private var onChange: (@MainActor () -> Void)?
    private var source: CFRunLoopSource?

    func start(_ onChange: @escaping @MainActor () -> Void) {
        guard source == nil else { return }
        self.onChange = onChange
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let loopSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            // The source is added to the main run loop, so the callback already runs on main.
            let observer = Unmanaged<LivePowerSourceObserver>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { observer.onChange?() }
        }, context)?.takeRetainedValue() else { return }
        source = loopSource
        CFRunLoopAddSource(CFRunLoopGetMain(), loopSource, .defaultMode)
    }
}
