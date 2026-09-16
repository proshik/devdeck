import Foundation

/// Battery state plus "who drained it" for the popover.
///
/// Lives app-wide rather than with the popover: the Mac is usually unplugged while the popover is
/// closed, and the baseline has to be taken at that moment. While on battery a snapshot every
/// minute keeps processes that exit before anyone looks; on AC the last discharge stays on screen,
/// frozen, until the next unplug starts a new one. Nothing is persisted.
@MainActor
@Observable
final class EnergyModel {
    private(set) var battery: BatteryState?
    /// The current (on battery) or last (back on AC) discharge; nil before the first unplug.
    private(set) var tally: EnergyTally?
    /// `tally` is live — the Mac is on battery right now.
    private(set) var isDischarging = false
    private(set) var consumers: [EnergyConsumer] = []

    static let consumerLimit = 5
    /// Background cadence: often enough to catch most exiting processes, cheap enough to ignore.
    static let backgroundInterval: Duration = .seconds(60)
    /// The popover's 2 s loop asks too; a new snapshot is taken at most this often.
    static let popoverSnapshotInterval: TimeInterval = 10

    @ObservationIgnored private let batteryProbe: BatteryProbing
    @ObservationIgnored private let energyProbe: ProcessEnergyProbing
    @ObservationIgnored private let observer: PowerSourceObserving
    @ObservationIgnored private let now: () -> Date
    /// Read live from the config (set by `AppDelegate`), so the Settings toggle needs no restart.
    @ObservationIgnored var isEnabled: () -> Bool = { true }
    /// nil until the power source has been seen once — then an "on battery" reading is not an unplug.
    @ObservationIgnored private var lastOnBattery: Bool?
    @ObservationIgnored private var inFlight = false
    @ObservationIgnored private var pendingForcedRefresh = false
    @ObservationIgnored private var loop: Task<Void, Never>?

    init(batteryProbe: BatteryProbing = LiveBatteryProbe(),
         energyProbe: ProcessEnergyProbing = LiveProcessEnergyProbe(),
         observer: PowerSourceObserving? = nil,
         now: @escaping () -> Date = Date.init) {
        self.batteryProbe = batteryProbe
        self.energyProbe = energyProbe
        self.observer = observer ?? LivePowerSourceObserver()
        self.now = now
    }

    /// Begin watching the power source and the minute-by-minute snapshots.
    func start() {
        guard loop == nil else { return }
        observer.start { [weak self] in
            Task { await self?.refresh(force: true) }
        }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh(force: true)
                try? await Task.sleep(for: Self.backgroundInterval)
            }
        }
    }

    /// Re-read the battery and advance the tally. `force` takes a snapshot regardless of how
    /// recent the last one is (power-source change, background tick); otherwise it is throttled.
    func refresh(force: Bool = false) async {
        guard !inFlight else {
            if force { pendingForcedRefresh = true }
            return
        }
        guard isEnabled() else { clear(); return }
        inFlight = true
        await advance(force: force)
        inFlight = false
        if pendingForcedRefresh {
            pendingForcedRefresh = false
            await refresh(force: true)
        }
    }

    private func advance(force: Bool) async {
        let batteryProbe = self.batteryProbe
        let state = await Task.detached(priority: .utility) { batteryProbe.state() }.value
        guard isEnabled() else { clear(); return }
        guard let state else { clear(); return }   // no battery on this Mac
        battery = state
        let previous = lastOnBattery
        lastOnBattery = state.onBattery

        if state.onBattery {
            if !isDischarging {
                let snapshot = await takeSnapshot()
                tally = EnergyTally(baseline: snapshot, at: now(), missedUnplug: previous != false)
                consumers = []
                isDischarging = true
            } else if force || isStale {
                record(await takeSnapshot())
            }
        } else if isDischarging {
            record(await takeSnapshot())   // the drain up to the replug, then freeze
            isDischarging = false
        }
    }

    private var isStale: Bool {
        guard let tally else { return true }
        return now().timeIntervalSince(tally.lastUpdate) >= Self.popoverSnapshotInterval
    }

    private func takeSnapshot() async -> [ProcessEnergy] {
        let energyProbe = self.energyProbe
        return await Task.detached(priority: .utility) { energyProbe.snapshot() }.value
    }

    private func record(_ snapshot: [ProcessEnergy]) {
        tally?.update(snapshot, at: now())
        consumers = tally?.top(Self.consumerLimit) ?? []
    }

    private func clear() {
        battery = nil
        tally = nil
        consumers = []
        isDischarging = false
        lastOnBattery = nil
    }
}
