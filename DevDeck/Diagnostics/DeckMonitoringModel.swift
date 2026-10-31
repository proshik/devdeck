import AppKit
import Observation

struct MonitoringContext: Equatable {
    var settings = MonitoringSettings()
    var hostEnabled = true
    var batteryEnabled = false
    var vmEnabled = false
    var minikubeEnabled = false
    var clusterEnabled = false
    var engine: ContainerEngineKind?
    var engineName: String?
    var engineRunning = false
}

/// A single owner for UI sampling. Cancellation invalidates publication immediately;
/// the old task retains its slot until blocking probes finish, preventing overlap on reopen.
@MainActor @Observable final class DeckMonitoringModel {
    private(set) var snapshot = DeckMonitoringSnapshot()
    private(set) var history: [MonitoringHistoryPoint] = []
    private(set) var context = MonitoringContext()
    private(set) var suspended = false
    var isCollecting: Bool { context.settings.enabled && !suspended && !readers.isEmpty }
    @ObservationIgnored private var readers: Set<UUID> = []
    @ObservationIgnored private var heavyTask: Task<Void, Never>?
    @ObservationIgnored private let heavySample: (@MainActor () async -> DeckMonitoringSnapshot)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var cpu = CPUBusyDelta()
    @ObservationIgnored private var previousHost: TimedMonitoring<HostMetricsSample>?
    @ObservationIgnored private var lastHeavy = Date.distantPast
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let intervalOverride: Duration?
    @ObservationIgnored private let waitForNext: (Duration) async throws -> Void
    @ObservationIgnored private let refresh: @MainActor () async -> Void
    @ObservationIgnored private let refreshHeavy: @MainActor () async -> Void
    @ObservationIgnored private let sample: @MainActor (Bool) async -> DeckMonitoringSnapshot
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var observationGeneration = UUID()

    init(interval: Duration? = nil, now: @escaping () -> Date = Date.init,
         waitForNext: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         refresh: @escaping @MainActor () async -> Void = {},
         refreshHeavy: @escaping @MainActor () async -> Void = {},
         heavySample: (@MainActor () async -> DeckMonitoringSnapshot)? = nil,
         sample: @escaping @MainActor (Bool) async -> DeckMonitoringSnapshot = { _ in .init() }) {
        self.waitForNext = waitForNext
        self.heavySample = heavySample
        self.now = now; intervalOverride = interval; self.refresh = refresh; self.refreshHeavy = refreshHeavy; self.sample = sample
    }

    convenience init(manager: ProcessManager, energy: EnergyModel, store: CommandStore, engine: EngineModel,
                     kernel: any MonitoringKernelProbing = LiveMonitoringKernelProbe(),
                     power: any MonitoringPowerProbing = LiveMonitoringPowerProbe()) {
        self.init(heavySample: {
            let settings = store.config.settings
            let engineKind = engine.activeKind
            var result = DeckMonitoringSnapshot()
            if (settings.vmMemoryMonitoring || settings.minikubeMemoryMonitoring || settings.clusterHealthMonitoring) {
                await manager.refreshVMSample()
                guard !Task.isCancelled else { return .init() }
                await manager.refreshClusterHealth()
                guard !Task.isCancelled else { return .init() }
                await manager.refreshVMDisk()
                guard !Task.isCancelled else { return .init() }
                await manager.refreshMinikubeSample()
                guard !Task.isCancelled else { return .init() }
                result.containers = .init(date: .now, value: .init(engine: engine.activeKind,
                    engineName: engine.activeName, running: engine.isActiveRunning,
                    vm: manager.vmMemorySample(), minikube: manager.minikubeSample(),
                    disk: manager.cachedVMDisk, cluster: manager.cachedClusterHealth, diskMeasuredAt: manager.cachedVMDiskDate))
            }
            guard !Task.isCancelled, store.config.settings == settings,
                  settings.monitoring.enabled, engine.activeKind == engineKind else { return .init() }
            return result
        }, sample: { _ in
            let settings = store.config.settings
            let engineKind = engine.activeKind
            var result = DeckMonitoringSnapshot()
            do {
                let value = await Task.detached(priority: .utility) { kernel.sample(includeMemory: settings.hostMemoryMonitoring) }.value
                guard !Task.isCancelled else { return .init() }
                result.mac = .init(date: .now, value: .init(sample: value, cpuBusyPercent: nil,
                                                          swapInBytesPerSecond: nil, swapOutBytesPerSecond: nil))
            }
            if settings.batteryMonitoring {
                await energy.refresh()
                guard !Task.isCancelled else { return .init() }
                let details = await Task.detached(priority: .utility) { power.sample() }.value
                guard !Task.isCancelled else { return .init() }
                result.energy = .init(date: .now, value: .init(battery: energy.battery, details: details,
                    consumers: energy.consumers, tally: energy.tally, isDischarging: energy.isDischarging))
            }
            guard !Task.isCancelled, store.config.settings == settings,
                  settings.monitoring.enabled, engine.activeKind == engineKind else { return .init() }
            return result
        })
    }

    /// Observation tracks config and engine changes even with no visible readers.
    func start(store: CommandStore, engine: EngineModel, manager: ProcessManager) {
        observationGeneration = UUID()
        observe(store: store, engine: engine, manager: manager, token: observationGeneration)
        guard observers.isEmpty else { return }
        for (name, asleep) in [(NSWorkspace.willSleepNotification, true), (NSWorkspace.didWakeNotification, false)] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in MainActor.assumeIsolated { self?.setSuspended(asleep) }
            })
        }
    }
    private func observe(store: CommandStore, engine: EngineModel, manager: ProcessManager, token: UUID) {
        guard token == observationGeneration else { return }
        let next = withObservationTracking {
            let s = store.config.settings
            return MonitoringContext(settings: s.monitoring, hostEnabled: s.hostMemoryMonitoring,
                batteryEnabled: s.batteryMonitoring, vmEnabled: s.vmMemoryMonitoring,
                minikubeEnabled: s.minikubeMemoryMonitoring, clusterEnabled: s.clusterHealthMonitoring,
                engine: engine.activeKind, engineName: engine.activeName, engineRunning: engine.isActiveRunning)
        } onChange: { [weak self, weak store, weak engine, weak manager] in
            Task { @MainActor in
                guard let self, let store, let engine, let manager else { return }
                self.observe(store: store, engine: engine, manager: manager, token: token)
            }
        }
        // UI master/interval/history changes must not invalidate active build sampling.
        if next.hostEnabled != context.hostEnabled || next.vmEnabled != context.vmEnabled
            || next.minikubeEnabled != context.minikubeEnabled || next.clusterEnabled != context.clusterEnabled
            || next.engine != context.engine || next.engineRunning != context.engineRunning {
            manager.invalidateMonitoringSamples()
        }
        configure(next)
    }
    func configure(_ next: MonitoringContext) {
        guard context != next else { return }
        if context.engine != next.engine || context.engineRunning != next.engineRunning {
            snapshot.containers = nil
            // VM points have no portable meaning across engines or VM restarts.
            for index in history.indices { history[index].vmMemory = nil }
        }
        if next.vmEnabled != context.vmEnabled || next.minikubeEnabled != context.minikubeEnabled
            || next.clusterEnabled != context.clusterEnabled || next.engine != context.engine
            || next.engineRunning != context.engineRunning { lastHeavy = .distantPast }
        context = next
        if !next.settings.historyEnabled { history.removeAll() }
        invalidate(); launchIfNeeded()
    }
    func setSuspended(_ value: Bool) {
        guard suspended != value else { return }
        suspended = value; invalidate(); launchIfNeeded()
    }
    var memoryStatus: String? {
        guard !context.settings.enabled || suspended || !context.hostEnabled else { return nil }
        let state = !context.hostEnabled ? L10n.monitoringMemoryOff : L10n.deckCollectionOff
        guard let date = snapshot.mac?.date else { return state }
        return state + " · " + L10n.monitoringLast + ": " + date.formatted(date: .omitted, time: .standard)
    }
    func begin(_ reader: UUID) { readers.insert(reader); launchIfNeeded() }
    func end(_ reader: UUID) {
        readers.remove(reader)
        if readers.isEmpty { invalidate() }
    }
    func stop() {
        observationGeneration = UUID(); readers.removeAll(); invalidate()
        for observer in observers { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observers.removeAll()
    }
    private func invalidate() {
        generation &+= 1; loop?.cancel(); cpu.reset(); previousHost = nil
        heavyTask?.cancel()
    }
    private func launchIfNeeded() {
        guard loop == nil, isCollecting else { return }
        let token = generation
        loop = Task { [weak self] in
            defer { self?.loop = nil; self?.launchIfNeeded() }
            while !Task.isCancelled {
                guard let self, self.isCollecting, token == self.generation else { return }
                await self.refresh()
                guard !Task.isCancelled, token == self.generation else { return }
                let heavy = self.now().timeIntervalSince(self.lastHeavy) >= 15
                if heavy, let heavySample = self.heavySample, self.heavyTask == nil {
                    self.lastHeavy = self.now()
                    self.heavyTask = Task { [weak self] in
                        let value = await heavySample()
                        guard let self else { return }
                        defer { self.heavyTask = nil }
                        guard !Task.isCancelled, token == self.generation else { return }
                        self.publish(value)
                    }
                }
                let value = await self.sample(heavy && self.heavySample == nil)
                guard !Task.isCancelled, token == self.generation else { return }
                if heavy && self.heavySample == nil {
                    await self.refreshHeavy()
                    guard !Task.isCancelled, token == self.generation else { return }
                    self.lastHeavy = self.now()
                }
                self.publish(value)
                do { try await self.waitForNext(self.intervalOverride ?? .seconds(self.context.settings.interval)) }
                catch { return }
            }
        }
    }
    private func publish(_ value: DeckMonitoringSnapshot) {
        if let mac = value.mac {
            var inRate: Double?, outRate: Double?
            if let host = mac.value.sample.host, host.countersAvailable {
                if let previousHost, mac.date > previousHost.date,
                   host.swapInsPages >= previousHost.value.swapInsPages,
                   host.swapOutsPages >= previousHost.value.swapOutsPages {
                    let rates = swapRatePagesPerSec(prevIn: previousHost.value.swapInsPages,
                        prevOut: previousHost.value.swapOutsPages, curIn: host.swapInsPages,
                        curOut: host.swapOutsPages, dtSeconds: mac.date.timeIntervalSince(previousHost.date))
                    inRate = rates.inPerSec * Double(hostPageSize); outRate = rates.outPerSec * Double(hostPageSize)
                }
                previousHost = .init(date: mac.date, value: host)
            } else { previousHost = nil }
            snapshot.mac = .init(date: mac.date, value: .init(sample: mac.value.sample,
                cpuBusyPercent: cpu.consume(mac.value.sample.cpu), swapInBytesPerSecond: inRate, swapOutBytesPerSecond: outRate))
        }
        if let containers = value.containers { snapshot.containers = containers }
        if let energy = value.energy, context.batteryEnabled { snapshot.energy = energy }
        if context.settings.historyEnabled, value.mac != nil || value.energy != nil || value.containers != nil {
            history.append(.init(date: value.mac?.date ?? value.energy?.date ?? value.containers!.date,
                cpu: value.mac == nil ? nil : snapshot.mac?.value.cpuBusyPercent,
                memory: value.mac?.value.sample.memory.map { $0.fraction * 100 },
                battery: value.energy?.value.battery.map { Double($0.percent) },
                vmMemory: value.containers?.value.vm.map { $0.fraction * 100 }))
            if history.count > MonitoringSettings.historyLimit { history.removeFirst(history.count - MonitoringSettings.historyLimit) }
        }
    }
}
