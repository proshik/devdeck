import Foundation

struct MonitoringSettings: Codable, Equatable, Sendable {
    var networkEnabled = true
    var networkInterface: String?
    var enabled = true
    var intervalSeconds = 2
    var historyEnabled = true
    var interval: Int { min(60, max(1, intervalSeconds)) }
    static let historyLimit = 180

    init(enabled: Bool = true, intervalSeconds: Int = 2, historyEnabled: Bool = true) {
        self.enabled = enabled
        self.intervalSeconds = intervalSeconds
        self.historyEnabled = historyEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        networkEnabled = try c.decodeIfPresent(Bool.self, forKey: .networkEnabled) ?? true
        networkInterface = try c.decodeIfPresent(String.self, forKey: .networkInterface)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        intervalSeconds = try c.decodeIfPresent(Int.self, forKey: .intervalSeconds) ?? 2
        historyEnabled = try c.decodeIfPresent(Bool.self, forKey: .historyEnabled) ?? true
    }
}
