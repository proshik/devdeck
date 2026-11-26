import CryptoKit
import Darwin
import Foundation

// The command-line entry (`DevDeck automation …`, stage 8 iteration 2) talks to the running app
// over a Unix socket: one JSON line of request, one JSON line of response. App Intents need a
// Team ID signature to run; this path works with the ad-hoc signature DevDeck ships with.

/// Exit codes of `DevDeck automation`. Listed in `--help`; agents and Shortcuts branch on them.
enum AutomationExitCode {
    /// Succeeded, a daemon came up, already running, opened in a terminal, stopped, any status, list.
    static let success: Int32 = 0
    /// The command or chain ran and failed (a cancelled sudo prompt counts: it did not run);
    /// a brightness write failed, read back another level or was replaced by a newer change.
    static let failed: Int32 = 1
    /// Still running when the wait ran out (run timeout; stop not done within the stop wait;
    /// no brightness readback within the brightness wait).
    static let timedOut: Int32 = 2
    /// Refused by a check: automation off, not allowed, unknown/ambiguous name, port, proxy,
    /// unknown/ambiguous/unsupported display…
    static let refused: Int32 = 3
    /// No DevDeck is listening for this build and data directory.
    static let appNotRunning: Int32 = 4
    /// The connection broke, the reply was unreadable or the versions differ.
    static let communication: Int32 = 5
    /// Bad arguments (`sysexits` EX_USAGE).
    static let usage: Int32 = 64

    /// How a report ends the process. `status` and `list` always succeed — they only read.
    static func code(for report: AutomationReport, operation: AutomationOperation) -> Int32 {
        switch operation {
        case .list, .status, .brightness, .proxy, .awake:
            return success
        case .stop:
            return report.status == .running || report.status == .timedOut ? timedOut : success
        case .run:
            switch report.status {
            case .succeeded, .running, .alreadyRunning, .openedInTerminal: return success
            case .timedOut: return timedOut
            case .failed, .stopped, .idle, .notRunning: return failed
            }
        }
    }
}

enum AutomationOperation: String, Codable, Sendable {
    case list, run, stop, status, brightness, proxy, awake
}

/// `DevDeck automation brightness …`: read or change display brightness the way the brightness
/// keys do. `percent` is the absolute value of `set` (0…100) or the step of `up`/`down` (nil =
/// the key step); `display` is a display name or UUID, nil = the keys' target.
struct AutomationBrightnessRequest: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable, CaseIterable {
        case list, get, set, up, down
    }

    var action: Action
    var percent: Double? = nil
    var display: String? = nil
}

/// `DevDeck automation proxy …`: pick, check and share proxies through `ProxyManager`. Never
/// carries a password; `target` is a proxy name or a remote proxy's UUID (`use` only).
struct AutomationProxyRequest: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case list, status, use, check, shareOn, shareOff, shareStatus, shareSet
    }

    var action: Action
    var target: String? = nil
    /// `shareSet` only: each nil field keeps its saved value.
    var port: Int? = nil
    var engine: ProxyEngine? = nil
    var serviceName: String? = nil
    var auth: Bool? = nil
    var username: String? = nil

    /// `none` after `use`: clear the selection.
    static let noneTarget = "none"
    static let validPorts = 1...65535

    var setsShareField: Bool { port != nil || engine != nil || serviceName != nil || auth != nil || username != nil }
}

/// `DevDeck automation awake …`: keep-awake through `AwakeModel`. `seconds` is `on`'s duration
/// (0 = indefinitely, nil = the duration chosen in the UI).
struct AutomationAwakeRequest: Codable, Equatable, Sendable {
    enum Action: String, Codable, Sendable {
        case on, off, status
    }

    var action: Action
    var seconds: Int? = nil
}

/// What the command line asks the app. Only saved items, by name or UUID — never a shell string.
struct AutomationRequest: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = AutomationRequest.currentVersion
    var operation: AutomationOperation
    var kind: AutomationReport.Kind? = nil
    var target: String? = nil
    /// Absolute already: the client resolves a relative path against its own working directory.
    var directory: String? = nil
    var timeoutSeconds: Int? = nil
    /// `operation == .brightness` only. Optional, so the protocol version stays 1.
    var brightness: AutomationBrightnessRequest? = nil
    /// `operation == .proxy` / `.awake` only. Optional, so the protocol version stays 1.
    var proxy: AutomationProxyRequest? = nil
    var awake: AutomationAwakeRequest? = nil
}

/// What the app answers: the text for each stream and the exit code, decided app-side.
struct AutomationResponse: Codable, Equatable, Sendable {
    var version: Int = AutomationRequest.currentVersion
    var exitCode: Int32
    var stdout: String
    var stderr: String
}

/// One JSON object per line in each direction; `JSONEncoder` escapes newlines inside strings.
enum AutomationWire {
    static let maxRequestBytes = 64 * 1024
    /// 30 lines of at most 1000 characters each plus the keys — far below this.
    static let maxResponseBytes = 1024 * 1024
    /// A client sends its request right after connecting; a silent peer is dropped after this.
    static let requestReadTimeout: TimeInterval = 5

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value) + Data("\n".utf8)
    }

    static func decodeRequest(_ data: Data) throws -> AutomationRequest {
        try JSONDecoder().decode(AutomationRequest.self, from: data)
    }

    static func decodeResponse(_ data: Data) throws -> AutomationResponse {
        try JSONDecoder().decode(AutomationResponse.self, from: data)
    }
}

/// Where a running DevDeck listens.
///
/// Not inside the data directory: a development data directory is easily longer than the 104
/// bytes of `sun_path`, and macOS has no `bindat`/`connectat`. The socket lives in the user's
/// caches instead, named by a hash of the bundle id and the data directory — so a development
/// build (its own bundle id, its own `--dev-data-directory`) can never reach the installed app.
enum AutomationEndpoint {
    /// `sun_path` is 104 bytes including the terminating NUL.
    static let maxPathBytes = 103

    /// `~/Library/Application Support/DevDeck` — where a release build keeps its data.
    static var installedDataDirectory: URL { AppRuntime.installedSupportDirectory }

    /// `~/Library/Caches/DevDeck` — created 0700 by the server.
    static var socketDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevDeck", isDirectory: true)
    }

    static func socketName(bundleID: String, dataDirectory: URL) -> String {
        let key = bundleID + "\n" + normalized(dataDirectory)
        let digest = SHA256.hash(data: Data(key.utf8))
        return "automation-" + digest.prefix(8).map { String(format: "%02x", $0) }.joined() + ".sock"
    }

    static func socketURL(bundleID: String, dataDirectory: URL) -> URL {
        socketDirectory.appendingPathComponent(socketName(bundleID: bundleID, dataDirectory: dataDirectory))
    }

    /// The same directory spelled differently (trailing slash, `..`, a symlink) hashes the same.
    private static func normalized(_ url: URL) -> String {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }
}

/// A `sockaddr_un` for a path that fits `sun_path`.
struct AutomationSocketAddress {
    private var storage = sockaddr_un()

    init?(path: String) {
        let bytes = Array(path.utf8)
        guard !bytes.isEmpty, bytes.count <= AutomationEndpoint.maxPathBytes else { return nil }
        storage.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &storage.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        storage.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    }

    mutating func withSockaddr<T>(_ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { body($0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
    }
}
