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

    /// Where the generated gost config lives. Fixed, not a temp path: orphan adoption after an app
    /// restart matches a surviving `gost` by its command line, so the path has to be the same in
    /// the next session as it was in the last one.
    static var configURL: URL {
        PrivateFile.applicationSupportDirectory.appendingPathComponent("gost.json")
    }

    /// The synthetic daemon `Command` fed to `ProcessManager`.
    ///
    /// gost v3 `auto://` serves HTTP and SOCKS on one listener. Credentials used to travel in the
    /// listener spec — `gost -L 'auto://user:pass@:9999'` — which put the password in the process's
    /// argv, and macOS lets **every** local account read the full argv of every process, root's
    /// included. So the whole service definition moves into a 0600 config file and the command line
    /// carries nothing but its path.
    ///
    /// A second problem disappears with it: the password no longer passes through a shell string,
    /// so a quote in it can no longer close the literal and run the remainder as commands.
    ///
    /// The string is also stable across a password change now, where it used to differ. That does
    /// NOT yet buy orphan adoption for this daemon: `findOrphan` matches a pre-shell command string
    /// against post-shell argv from `ps`, and the quotes here (needed — the config path can contain
    /// a space) never appear in argv. Adoption of the listener has therefore never worked, before
    /// this change or after it; a surviving gost surfaces as an occupied port instead. Recorded
    /// rather than fixed here, because the defect is in the matching, not in this string.
    ///
    /// `watchdogEnabled` is what gives the "gost keeps dying" problem its auto-restart.
    func toCommand(gostPath: String, configPath: String) -> Command {
        Command(
            id: Self.daemonID,
            name: L10n.proxyShareDaemonName,
            command: "\(shellQuote(gostPath)) -C \(shellQuote(configPath))",
            isDaemon: true,
            watchdogEnabled: true,
            port: port
        )
    }

    /// The gost service definition, as JSON. Pure.
    ///
    /// JSON rather than gost's YAML for one reason: `JSONEncoder` escapes the credentials for us.
    /// Hand-rolling YAML would mean hand-rolling the escaping of a value chosen by the user, in the
    /// one place where getting it wrong hands over the password — the mistake this whole change
    /// exists to undo. gost accepts either format, keyed off the file extension.
    ///
    /// Keys are sorted so the output is deterministic and the tests can assert it verbatim.
    /// Credentials are omitted entirely unless auth is on AND a username exists, mirroring the
    /// listener spec this replaces: gost treats an absent `auth` block as an open proxy.
    func gostConfigJSON(password: String?) -> String? {
        let auth = (authEnabled && !username.isEmpty)
            ? GostAuth(username: username, password: password ?? "")
            : nil
        let config = GostConfig(services: [
            GostService(
                name: "devdeck-proxy",
                addr: ":\(port)",
                handler: GostHandler(type: "auto", auth: auth),
                listener: GostListener(type: "tcp")
            )
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(config) else {
            DiagnosticLog.shared.log("Proxy share: could not encode the gost config", level: .error)
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - gost config file

/// gost v3's config schema, only the slice we generate. Encode-only — DevDeck writes this file and
/// never reads it back. Verified against `gost -L 'auto://user:pass@:port' -O yaml`, which prints
/// the canonical config for a listener spec.
struct GostConfig: Encodable, Equatable {
    let services: [GostService]
}

struct GostService: Encodable, Equatable {
    let name: String
    let addr: String
    let handler: GostHandler
    let listener: GostListener
}

struct GostHandler: Encodable, Equatable {
    let type: String
    /// Absent for an open proxy — the key is omitted, not sent empty.
    let auth: GostAuth?
}

struct GostAuth: Encodable, Equatable {
    let username: String
    let password: String
}

struct GostListener: Encodable, Equatable {
    let type: String
}
