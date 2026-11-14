import Foundation

enum NetworkQualityFailure: Error, Equatable { case unavailable, network, timeout, cancelled, invalidOutput }
struct NetworkQualityResult: Equatable, Sendable {
    var date: Date
    var interface: String?
    var download: Double
    var upload: Double
    var responsiveness: Double?
    var latency: Double?
    static func parse(_ data: Data, date: Date) throws -> Self {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["error_code"] == nil || (json["error_code"] as? Int) == 0,
              let down = json["dl_throughput"] as? Double,
              let up = json["ul_throughput"] as? Double,
              down.isFinite, up.isFinite, down >= 0, up >= 0 else { throw NetworkQualityFailure.invalidOutput }
        func optional(_ key: String) -> Double? {
            guard let value = json[key] as? Double, value.isFinite, value >= 0 else { return nil }
            return value
        }
        return .init(date: date, interface: json["interface_name"] as? String, download: down, upload: up,
                     responsiveness: optional("responsiveness"), latency: optional("base_rtt"))
    }
}
protocol NetworkQualityTesting: Sendable {
    func run(interface: String?) async throws -> NetworkQualityResult
}
struct LiveNetworkQualityTest: NetworkQualityTesting {
    func run(interface: String?) async throws -> NetworkQualityResult {
        let scope = MonitoringCancellation()
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) {
                guard !scope.isCancelled else { throw NetworkQualityFailure.cancelled }
                guard let child = SpawnedMonitoringChild("/usr/bin/networkQuality", ["-c", "-M", "30"] + (interface.map { ["-I", $0] } ?? [])) else {
                    throw NetworkQualityFailure.unavailable
                }
                return try Self.collect(child, cancelled: { scope.isCancelled })
            }.value
        } onCancel: { scope.cancel() }
    }
    static func collect(_ child: any MonitoringChild, cancelled: () -> Bool,
                        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                        wait: () -> Void = { Thread.sleep(forTimeInterval: 0.02) },
                        timeout: TimeInterval = 40) throws -> NetworkQualityResult {
        defer { child.terminateGroupAndReap() }
        let deadline = now() + timeout
        var output = Data()
        while true {
            if cancelled() { throw NetworkQualityFailure.cancelled }
            if now() >= deadline { throw NetworkQualityFailure.timeout }
            output.append(child.readAvailable())
            guard output.count <= 4 * 1024 * 1024 else { throw NetworkQualityFailure.invalidOutput }
            if let success = child.finishedSuccessfully {
                guard success else { throw NetworkQualityFailure.network }
                while true {
                    if cancelled() { throw NetworkQualityFailure.cancelled }
                    if now() >= deadline { throw NetworkQualityFailure.timeout }
                    let tail = child.readAvailable()
                    if tail.isEmpty { break }
                    output.append(tail)
                    guard output.count <= 4 * 1024 * 1024 else { throw NetworkQualityFailure.invalidOutput }
                }
                return try NetworkQualityResult.parse(output, date: .now)
            }
            wait()
        }
    }
}
