import XCTest
import SwiftUI
@testable import DevDeck

@MainActor final class MonitoringCorrectionsTests: XCTestCase {
    private func populatedModel(host: Bool = true, battery: Bool = true) async -> DeckMonitoringModel {
        let sampled = expectation(description: "sample")
        let model = DeckMonitoringModel(interval: .seconds(60), sample: { _ in
            sampled.fulfill()
            return .init(mac: .init(date: .now, value: .init(sample: .init(
                cpu: .init(user: 10, system: 10, idle: 80, nice: 0), loadAverage: 2, memory: .init(usedBytes: 40, totalBytes: 100),
                diskUsedBytes: 40, diskTotalBytes: 100, uptime: 900), cpuBusyPercent: nil,
                swapInBytesPerSecond: nil, swapOutBytesPerSecond: nil)),
                containers: .init(date: .now, value: .init(engine: .colima, engineName: "Colima",
                    running: true, vm: .init(usedBytes: 50, limitBytes: 100), minikube: nil, disk: nil, cluster: nil)),
                energy: battery ? .init(date: .now, value: .init(battery: .init(percent: 80, isCharging: false,
                    onBattery: true, minutesRemaining: nil), details: .init(), consumers: [], tally: nil, isDischarging: true)) : nil)
        })
        model.configure(.init(hostEnabled: host, batteryEnabled: battery, engine: .colima, engineRunning: true))
        let reader = UUID(); model.begin(reader)
        await fulfillment(of: [sampled], timeout: 1)
        model.end(reader)
        return model
    }
    func testMemoryGateDoesNotSuppressOtherMacMetrics() async {
        let model = await populatedModel(host: false)
        XCTAssertEqual(model.snapshot.mac?.value.sample.diskUsedBytes, 40)
        XCTAssertEqual(model.snapshot.mac?.value.sample.loadAverage, 2)
        XCTAssertEqual(model.snapshot.mac?.value.sample.uptime, 900)
        XCTAssertNotNil(model.snapshot.mac?.value.sample.cpu)
    }
    func testEngineSwitchRemovesOnlyVMHistory() async {
        let model = await populatedModel()
        XCTAssertEqual(model.history.first?.vmMemory, 50)
        XCTAssertEqual(model.history.first?.battery, 80)
        let dates = model.history.map(\.date)
        let cpu = model.history.map(\.cpu)
        let memory = model.history.map(\.memory)
        let battery = model.history.map(\.battery)
        model.configure(.init(engine: .dockerDesktop, engineRunning: true))
        XCTAssertTrue(model.history.allSatisfy { $0.vmMemory == nil })
        XCTAssertEqual(model.history.map(\.date), dates)
        XCTAssertEqual(model.history.map(\.cpu), cpu)
        XCTAssertEqual(model.history.map(\.memory), memory)
        XCTAssertEqual(model.history.map(\.battery), battery)
        XCTAssertNil(model.snapshot.containers)
    }
}


private struct MonitoringBootFixture: BootTimeProviding {
    let value: Date
    func bootTime() -> Date { value }
}

extension MonitoringCorrectionsTests {
    func testUptimeUsesBootDateAndClockIncludingSleepAndRejectsInvalidDates() {
        let boot = Date(timeIntervalSince1970: 1_700_000_000)
        var clock = boot.addingTimeInterval(3600)
        let uptime = MonitoringUptime(source: MonitoringBootFixture(value: boot), now: { clock })
        XCTAssertEqual(uptime.sample(), 3600)
        clock = clock.addingTimeInterval(7200) // elapsed wall time, including a sleep interval
        XCTAssertEqual(uptime.sample(), 10800)
        for invalid in [Date.distantPast, Date(timeIntervalSince1970: 0), clock.addingTimeInterval(1),
                        Date(timeIntervalSince1970: .infinity)] {
            XCTAssertNil(MonitoringUptime(source: MonitoringBootFixture(value: invalid), now: { clock }).sample())
        }
    }

    func testNativeProbeSkipsBothMemorySourcesWhenDisabled() {
        let probe = LiveMonitoringKernelProbe(readBase: {
            .init(cpu: .init(user: 2, system: 1, idle: 7, nice: 0), loadAverage: 1,
                  diskUsedBytes: 40, diskTotalBytes: 100, uptime: 200)
        }, readMemory: { XCTFail("memory read while disabled"); return nil },
           readHost: { XCTFail("host counters read while disabled"); return nil })
        let value = probe.sample(includeMemory: false)
        XCTAssertNotNil(value.cpu)
        XCTAssertEqual(value.diskUsedBytes, 40)
        XCTAssertEqual(value.uptime, 200)
        XCTAssertNil(value.memory)
        XCTAssertNil(value.host)
    }

    func testProductionSamplerPassesMemoryGateWithoutStoppingMac() async throws {
        let sampled = expectation(description: "native base sampled")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CommandStore(configURL: directory.appendingPathComponent("config.json"))
        store.setHostMonitoring(false)
        store.setVMMonitoring(false)
        store.setMinikubeMonitoring(false)
        store.setClusterHealth(false)
        store.setBatteryMonitoring(false)
        let probe = LiveMonitoringKernelProbe(readBase: {
            sampled.fulfill()
            return .init(cpu: .init(user: 2, system: 1, idle: 7, nice: 0), loadAverage: 3,
                         diskUsedBytes: 40, diskTotalBytes: 100, uptime: 200)
        }, readMemory: { XCTFail("memory read while disabled"); return nil },
           readHost: { XCTFail("host counters read while disabled"); return nil })
        let energy = EnergyModel(batteryProbe: FakeBatteryProbe(), energyProbe: FakeProcessEnergyProbe(),
                                 observer: FakePowerSourceObserver())
        let model = DeckMonitoringModel(manager: ProcessManager(runner: FakeCommandRunner(), vmMonitoringEnabled: { false }, hostMonitoringEnabled: { false }), energy: energy,
                                       store: store, engine: EngineModel(candidates: []), kernel: probe)
        model.configure(.init(hostEnabled: false))
        let reader = UUID(); model.begin(reader)
        await fulfillment(of: [sampled], timeout: 1)
        for _ in 0..<100 where model.snapshot.mac == nil { try await Task.sleep(for: .milliseconds(5)) }
        model.end(reader)
        XCTAssertEqual(model.snapshot.mac?.value.sample.diskUsedBytes, 40)
        XCTAssertEqual(model.snapshot.mac?.value.sample.loadAverage, 3)
        XCTAssertNil(model.snapshot.mac?.value.sample.memory)
        XCTAssertNil(model.snapshot.mac?.value.sample.host)
    }

    func testVMRestartClearsOnlyVMSeries() async {
        let model = await populatedModel()
        let memory = model.history.map(\.memory)
        let battery = model.history.map(\.battery)
        model.configure(.init(engine: .colima, engineRunning: false))
        XCTAssertTrue(model.history.allSatisfy { $0.vmMemory == nil })
        XCTAssertEqual(model.history.map(\.memory), memory)
        XCTAssertEqual(model.history.map(\.battery), battery)
    }

    func testEmptySectionFixturesWithNonemptyMacHistory() async throws {
        let model = await populatedModel(battery: false)
        model.configure(.init(engine: .dockerDesktop, engineRunning: true))
        XCTAssertTrue(MonitoringHistoryView.hasMeasurements(model.history, section: .mac))
        let oldLanguage = LocalizationManager.shared.language
        defer { LocalizationManager.shared.language = oldLanguage }
        for language in AppLanguage.allCases {
            LocalizationManager.shared.language = language
            for section in [MonitoringSection.containers, .energy] {
                XCTAssertFalse(MonitoringHistoryView.hasMeasurements(model.history, section: section))
                let hosting = NSHostingView(rootView: MonitoringHistoryView(section: section).environment(model)
                    .padding().frame(width: 380, height: 200).background(Color(nsColor: .windowBackgroundColor)))
                hosting.frame = NSRect(x: 0, y: 0, width: 380, height: 200)
                hosting.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds))
                hosting.cacheDisplay(in: hosting.bounds, to: bitmap)
                let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("devdeck-stage6-empty-history")
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try data.write(to: directory.appendingPathComponent("\(section)-\(language.rawValue).png"))
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
                attachment.name = "empty-\(section)-\(language.rawValue)"; attachment.lifetime = .keepAlways; add(attachment)
            }
        }
    }
}
