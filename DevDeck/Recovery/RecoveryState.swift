import Foundation

/// Sets (`true`) and clears (`false`) a recovery marker around a risky operation. Models take it as
/// a closure so they stay independent of `RecoveryModel`; the default does nothing.
typealias RecoveryMarking = @MainActor (RecoveryOperation, _ running: Bool) -> Void

/// Additional modules that recovery can switch off (REC-01). Commands, daemons, chains, proxies,
/// the configuration and manual update checks are not among them: they keep working.
enum RecoveryModule: String, CaseIterable, Codable, CodingKeyRepresentable, Comparable, Sendable {
    case clipboard, brightness, monitoring, network, agentTabRestore, autoUpdateInstall, automationCLI

    static func < (lhs: Self, rhs: Self) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

/// One-shot or risky operations that mark themselves while they run. A process that dies with the
/// mark set points at the operation; twice in a row switches off its module.
enum RecoveryOperation: String, CaseIterable, Codable, CodingKeyRepresentable, Sendable {
    case tabRestore, heavyProbes, displayDiscovery, updateInstall

    var module: RecoveryModule {
        switch self {
        case .tabRestore: .agentTabRestore
        case .heavyProbes: .monitoring
        case .displayDiscovery: .brightness
        case .updateInstall: .autoUpdateInstall
        }
    }

    /// Bit in the marker byte. Order is the file format: append only.
    var bit: UInt8 {
        switch self {
        case .tabRestore: 1 << 0
        case .heavyProbes: 1 << 1
        case .displayDiscovery: 1 << 2
        case .updateInstall: 1 << 3
        }
    }

    static func from(mask: UInt8) -> Set<RecoveryOperation> {
        Set(allCases.filter { mask & $0.bit != 0 })
    }
}

enum RecoverySuspensionReason: Codable, Equatable, Sendable {
    /// The process died inside this operation twice in a row (or, for an update, it did not
    /// install twice).
    case operationCrashed(RecoveryOperation)
    /// Three unclean exits in a row, each within the first minutes of the process.
    case repeatedCrashes
}

struct RecoverySuspension: Codable, Equatable, Sendable {
    var reason: RecoverySuspensionReason
    var since: Date
}

/// The previous process, as it left itself.
struct RecoveryRunRecord: Codable, Equatable, Sendable {
    /// `kern.boottime` in whole seconds — a different value means the Mac restarted in between.
    var bootTime: Int
    var launchedAt: Date
    var cleanExit: Bool
    var survivedEarlyWindow: Bool
}

/// Everything recovery keeps, in its own 0600 file beside the config. `config.json` and the
/// session snapshot are never written by recovery.
struct RecoveryState: Codable, Equatable, Sendable {
    var lastRun: RecoveryRunRecord?
    var earlyUncleanExits = 0
    var strikes: [RecoveryOperation: Int] = [:]
    var suspended: [RecoveryModule: RecoverySuspension] = [:]
    /// Build Sparkle was about to install when the previous process quit for it.
    var pendingUpdateBuild: String?

    init() {}

    enum CodingKeys: String, CodingKey { case lastRun, earlyUncleanExits, strikes, suspended, pendingUpdateBuild }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastRun = try c.decodeIfPresent(RecoveryRunRecord.self, forKey: .lastRun)
        earlyUncleanExits = try c.decodeIfPresent(Int.self, forKey: .earlyUncleanExits) ?? 0
        strikes = try c.decodeIfPresent([RecoveryOperation: Int].self, forKey: .strikes) ?? [:]
        suspended = try c.decodeIfPresent([RecoveryModule: RecoverySuspension].self, forKey: .suspended) ?? [:]
        pendingUpdateBuild = try c.decodeIfPresent(String.self, forKey: .pendingUpdateBuild)
    }

    static func encode(_ state: RecoveryState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(state)
    }

    /// A missing or damaged file is an empty state: recovery must never stop DevDeck from starting.
    static func decode(_ data: Data?) -> RecoveryState {
        guard let data else { return RecoveryState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(RecoveryState.self, from: data)) ?? RecoveryState()
    }
}

/// The rules of REC-01, as a pure function of what the previous process left behind.
enum RecoveryPolicy {
    static let operationStrikeLimit = 2
    static let earlyExitLimit = 3
    /// A process that lived this long is past its startup: a later crash breaks the series.
    static let earlyWindow: TimeInterval = 5 * 60

    static func evaluateLaunch(_ previous: RecoveryState, markers: Set<RecoveryOperation>, bootTime: Int,
                               installedBuild: String, now: Date)
        -> (state: RecoveryState, newlySuspended: [RecoveryModule]) {
        var state = previous
        var newly: [RecoveryModule] = []

        func strike(_ operation: RecoveryOperation) {
            let count = (state.strikes[operation] ?? 0) + 1
            state.strikes[operation] = count
            guard count >= operationStrikeLimit else { return }
            state.strikes[operation] = nil
            suspend(operation.module, .operationCrashed(operation))
        }
        func suspend(_ module: RecoveryModule, _ reason: RecoverySuspensionReason) {
            guard state.suspended[module] == nil else { return }
            state.suspended[module] = RecoverySuspension(reason: reason, since: now)
            newly.append(module)
        }

        // The update outcome does not depend on how the previous process ended: Sparkle quits the
        // app cleanly to install, and the next launch shows whether it worked.
        if let pending = state.pendingUpdateBuild {
            state.pendingUpdateBuild = nil
            if pending == installedBuild { state.strikes[.updateInstall] = nil } else { strike(.updateInstall) }
        }

        if let last = previous.lastRun, last.bootTime == bootTime, !last.cleanExit {
            let attributed = markers.subtracting([.updateInstall])
            if !attributed.isEmpty {
                for operation in RecoveryOperation.allCases where attributed.contains(operation) { strike(operation) }
            } else if last.survivedEarlyWindow {
                state.earlyUncleanExits = 0
            } else {
                state.earlyUncleanExits += 1
                if state.earlyUncleanExits >= earlyExitLimit {
                    state.earlyUncleanExits = 0
                    for module in RecoveryModule.allCases { suspend(module, .repeatedCrashes) }
                }
            }
        } else if previous.lastRun?.cleanExit == true {
            state.earlyUncleanExits = 0
        }

        state.lastRun = RecoveryRunRecord(bootTime: bootTime, launchedAt: now, cleanExit: false, survivedEarlyWindow: false)
        return (state, newly.sorted())
    }
}
