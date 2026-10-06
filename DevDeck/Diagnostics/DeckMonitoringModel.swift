import Foundation
import Observation

/// One sampling loop while a panel or monitoring page is visible. A second window
/// subscribes to the same caches without starting a competing set of CLI probes.
@MainActor
@Observable
final class DeckMonitoringModel {
    private let refresh: @MainActor () async -> Void
    private let refreshHeavy: @MainActor () async -> Void
    private let interval: Duration
    @ObservationIgnored private var readers: Set<UUID> = []
    @ObservationIgnored private var loop: Task<Void, Never>?

    convenience init(manager: ProcessManager, energy: EnergyModel) {
        self.init(refresh: {
            await manager.refreshVMSample()
            await manager.refreshHostSample()
            await energy.refresh()
        }, refreshHeavy: {
            await manager.refreshClusterHealth()
            await manager.refreshVMDisk()
            await manager.refreshMinikubeSample()
        })
    }

    init(interval: Duration = .seconds(2),
         refresh: @escaping @MainActor () async -> Void,
         refreshHeavy: @escaping @MainActor () async -> Void) {
        self.interval = interval
        self.refresh = refresh
        self.refreshHeavy = refreshHeavy
    }

    func begin(_ reader: UUID) {
        readers.insert(reader)
        guard loop == nil else { return }
        loop = Task { [weak self] in
            var heavyRefresh = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                guard !self.readers.isEmpty else { self.loop = nil; return }
                await self.refresh()
                if Date().timeIntervalSince(heavyRefresh) >= 15 {
                    await self.refreshHeavy()
                    heavyRefresh = .now
                }
                do { try await Task.sleep(for: self.interval) }
                catch { self.loop = nil; return }
            }
        }
    }

    func end(_ reader: UUID) {
        readers.remove(reader)
        // The loop notices the empty reader set after the current probe/sleep. A
        // newly opened view reuses it instead of overlapping an in-flight probe.
    }
}
