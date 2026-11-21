import Foundation
import Observation

@MainActor @Observable
final class NetworkMonitoringModel {
    var interfaces: [NetworkInterfaceSample] = []
    private(set) var source: NetworkInterfaceSample?
    private(set) var selected: String?
    var point: NetworkTrafficPoint?
    var measuredAt: Date?
    var history: [NetworkTrafficPoint] = []
    var totals = NetworkTrafficAccumulator()
    private(set) var collecting = false
    /// Switched off by crash recovery (REC-01): no sampling until switched back on. The manual
    /// speed test stays an explicit action and is not gated.
    private(set) var isHalted = false
    var runningTest = false
    var result: NetworkQualityResult?
    var failure: NetworkQualityFailure?
    private struct Configuration: Equatable {
        var enabled: Bool
        var interface: String?
        var interval: Int
        var historyEnabled: Bool
        var suspended: Bool
    }
    @ObservationIgnored private var desired: Configuration?
    @ObservationIgnored private var observedInterface: String?
    @ObservationIgnored private var readers: Set<UUID> = []
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var test: Task<Void, Never>?
    @ObservationIgnored private let probe: any NetworkInterfaceProbing
    @ObservationIgnored private let routes: any NetworkRouteProbing
    @ObservationIgnored private let uptime: @Sendable () -> TimeInterval
    @ObservationIgnored private let waitForNext: (Duration) async throws -> Void
    @ObservationIgnored private let quality: any NetworkQualityTesting
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var testGeneration = UUID()
    @ObservationIgnored private var terminating = false
    var hasPendingTest: Bool { test != nil }
    func prepareForTermination() { terminating = true; cancelTest() }
    func waitForTestCleanup() async { if let test { await test.value } }
    init(probe: any NetworkInterfaceProbing = LiveNetworkInterfaceProbe(),
         routes: any NetworkRouteProbing = LiveNetworkRouteProbe(),
         uptime: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         waitForNext: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         quality: any NetworkQualityTesting = LiveNetworkQualityTest()) {
        self.probe = probe; self.routes = routes; self.uptime = uptime; self.waitForNext = waitForNext; self.quality = quality
    }
    func begin(_ reader: UUID) {
        readers.insert(reader)
        launchIfNeeded()
    }
    func end(_ reader: UUID) {
        readers.remove(reader)
        if readers.isEmpty { stopSampling() }
    }
    func configure(enabled: Bool, interface: String?, interval: Int, historyEnabled: Bool, suspended: Bool = false) {
        let next = Configuration(enabled: enabled, interface: interface, interval: max(1, interval),
                                 historyEnabled: historyEnabled, suspended: suspended)
        guard desired != next else { launchIfNeeded(); return }
        let interfaceChanged = selected != interface
        desired = next
        if interfaceChanged {
            selected = interface; observedInterface = nil; source = nil
            history.removeAll(); totals = .init(); point = nil; measuredAt = nil
        }
        if !historyEnabled { history.removeAll() }
        // A cadence/history edit is still the same observed session. Stopping, sleep,
        // or selecting another interface starts a fresh delta interval.
        invalidate(resetInterval: interfaceChanged || !shouldCollect)
        launchIfNeeded()
    }
    private var shouldCollect: Bool {
        !isHalted && (desired.map { $0.enabled && !$0.suspended && !readers.isEmpty } ?? false)
    }
    func setHalted(_ value: Bool) {
        guard isHalted != value else { return }
        isHalted = value
        invalidate(resetInterval: true)
        launchIfNeeded()
    }
    private func invalidate(resetInterval: Bool) {
        generation = UUID(); loop?.cancel()
        if resetInterval { totals.resetInterval() }
        collecting = shouldCollect
    }
    private func launchIfNeeded() {
        collecting = shouldCollect
        guard loop == nil, collecting, let configuration = desired else { return }
        let token = generation, probe = probe, routes = routes
        loop = Task { [weak self] in
            // Cancellation invalidates publication immediately, but does not release this
            // slot until the detached synchronous probe has actually returned.
            defer { self?.loop = nil; self?.launchIfNeeded() }
            while !Task.isCancelled {
                guard let self, self.shouldCollect, self.generation == token else { return }
                let reading = await Task.detached(priority: .utility) {
                    (probe.sample(), routes.sample())
                }.value
                guard !Task.isCancelled, self.generation == token else { return }
                self.accept(reading.0, routes: reading.1, uptime: self.uptime(), date: .now,
                            historyEnabled: configuration.historyEnabled)
                do { try await self.waitForNext(.seconds(configuration.interval)) } catch { return }
            }
        }
    }
    func accept(_ samples: [NetworkInterfaceSample]?, routes: NetworkRoutes = .init(), uptime: TimeInterval, date: Date, historyEnabled: Bool) {
        interfaces = samples ?? []
        let sample: NetworkInterfaceSample?
        if let selected {
            sample = interfaces.first { $0.id == selected }
        } else {
            // IPv4 is preferred on dual-stack connections. IPv6 also works on its own
            // or when its primary interface is the only available counter source.
            sample = [routes.ipv4, routes.ipv6].compactMap { $0 }.compactMap { id in
                interfaces.first { $0.id == id }
            }.first
        }
        source = sample
        if let id = sample?.id, id != observedInterface {
            observedInterface = id; totals.select(id); history.removeAll()
        }
        point = totals.consume(sample, uptime: uptime, date: date)
        measuredAt = sample == nil ? nil : date
        if historyEnabled, let point { history.append(point) }
        if history.count > MonitoringSettings.historyLimit { history.removeFirst(history.count - MonitoringSettings.historyLimit) }
    }
    func stopSampling() {
        invalidate(resetInterval: true)
    }
    func runTest() {
        guard test == nil, !terminating else { return }
        runningTest = true; failure = nil
        let token = UUID(); testGeneration = token
        let interface = selected, quality = quality
        test = Task { [weak self] in
            // Own the task until the backend has returned, including group kill/reap.
            // Cancellation invalidates the result but cannot release this slot early.
            defer { self?.test = nil; self?.runningTest = false }
            do {
                let value = try await quality.run(interface: interface)
                guard let self, self.testGeneration == token else { return }
                self.result = value
            } catch {
                guard let self, self.testGeneration == token else { return }
                self.failure = error as? NetworkQualityFailure ?? .network
            }
        }
    }
    func cancelTest() {
        guard let test else { return }
        testGeneration = UUID(); test.cancel(); failure = .cancelled
    }
    func stop() { readers.removeAll(); stopSampling(); cancelTest() }
}
