import Foundation

/// Host-side proxy sharing configuration, persisted in config.json under the `proxy` key.
///
/// This machine runs a `gost` listener (HTTP+SOCKS on one port) that other machines on the LAN
/// reach through the VPN tunnel this machine holds. The listener itself is NOT a new subsystem:
/// it is expressed as a synthetic daemon `Command` and handed to the existing supervision engine
/// (watchdog restarts, orphan adoption, occupied-port panel).
///
/// The password is deliberately NOT stored here — it lives in the Keychain
/// (`ProxyCredentialStore`), so config.json stays safe to share and hand-edit.
/// Decoding is resilient: every key falls back to its default.
struct ProxyShare: Codable, Equatable {
    /// TCP port `gost` listens on (announced over Bonjour).
    var port: Int
    /// Require `user:pass` from clients. The password comes from the Keychain at launch time.
    var authEnabled: Bool
    /// Username clients must present when `authEnabled`.
    var username: String
    /// Bonjour service name to announce. Empty → the host name is used.
    var serviceName: String

    init(port: Int = 9999, authEnabled: Bool = false, username: String = "", serviceName: String = "") {
        self.port = port
        self.authEnabled = authEnabled
        self.username = username
        self.serviceName = serviceName
    }

    enum CodingKeys: String, CodingKey {
        case port, authEnabled, username, serviceName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 9999
        authEnabled = try c.decodeIfPresent(Bool.self, forKey: .authEnabled) ?? false
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName) ?? ""
    }

    /// Stable id for the synthetic `gost` daemon. Fixed (not random) so supervision state,
    /// orphan adoption after a restart and the Keychain account key all agree across sessions.
    static let daemonID = UUID(uuidString: "6057D9E0-0000-4000-8000-000000000001")!

    /// Homebrew install locations, Apple Silicon first.
    static let gostCandidates = ["/opt/homebrew/bin/gost", "/usr/local/bin/gost"]

    /// Path to an installed `gost`, or nil when it isn't installed (→ the UI warns, nothing starts).
    var gostPath: String? { Self.gostCandidates.first { FileManager.default.fileExists(atPath: $0) } }

    /// The announced Bonjour name: the configured one, or this machine's host name.
    var effectiveServiceName: String {
        let trimmed = serviceName.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? Self.defaultServiceName : trimmed
    }

    /// Host name without the `.local` suffix Bonjour appends itself.
    static var defaultServiceName: String {
        let host = ProcessInfo.processInfo.hostName
        return host.hasSuffix(".local") ? String(host.dropLast(6)) : host
    }

    /// The synthetic daemon `Command` fed to `ProcessManager`.
    ///
    /// gost v3 `auto://` serves HTTP and SOCKS on one listener; credentials are optional:
    ///   open: `gost -L 'auto://:9999'`   ·   auth: `gost -L 'auto://user:pass@:9999'`
    ///
    /// The password only ever reaches the argv (see the `ps` caveat in the plan) — logs key off
    /// `Command.name`, so it never lands in devdeck.log or config.json. `watchdogEnabled` is what
    /// gives the "gost keeps dying" problem its auto-restart.
    func toCommand(gostPath: String, password: String?) -> Command {
        let creds = (authEnabled && !username.isEmpty) ? "\(username):\(password ?? "")@" : ""
        let listener = "auto://\(creds):\(port)"
        return Command(
            id: Self.daemonID,
            name: L10n.proxyShareDaemonName,
            command: "\(gostPath) -L '\(listener)'",
            isDaemon: true,
            watchdogEnabled: true,
            port: port
        )
    }
}
