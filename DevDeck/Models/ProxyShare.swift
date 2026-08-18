import Foundation

/// Which implementation serves the share. `builtIn` is the default: an in-process HTTP
/// CONNECT/absolute-form listener with no external dependency. `gost` remains for peers
/// that need SOCKS.
enum ProxyEngine: String, Codable, CaseIterable {
    case builtIn, gost
}

/// Host-side proxy sharing configuration, persisted in config.json under the `proxy` key.
///
/// This machine runs a proxy listener that other machines on the LAN reach through the VPN tunnel
/// this machine holds — either the built-in in-process engine or an external `gost` (HTTP+SOCKS on
/// one port). The listener itself is NOT a new subsystem: it is expressed as a synthetic daemon
/// `Command` and handed to the existing supervision engine (watchdog restarts, orphan adoption,
/// occupied-port panel).
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
    /// Which implementation serves the share (see `ProxyEngine`).
    var engine: ProxyEngine

    init(port: Int = 9999, authEnabled: Bool = false, username: String = "", serviceName: String = "",
         engine: ProxyEngine = .builtIn) {
        self.port = port
        self.authEnabled = authEnabled
        self.username = username
        self.serviceName = serviceName
        self.engine = engine
    }

    enum CodingKeys: String, CodingKey {
        case port, authEnabled, username, serviceName, engine
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        port = try c.decodeIfPresent(Int.self, forKey: .port) ?? 9999
        authEnabled = try c.decodeIfPresent(Bool.self, forKey: .authEnabled) ?? false
        username = try c.decodeIfPresent(String.self, forKey: .username) ?? ""
        serviceName = try c.decodeIfPresent(String.self, forKey: .serviceName) ?? ""
        // Resilient like every other key — and an unknown STRING (a config written by a newer
        // version) falls back rather than failing the whole config.
        let rawEngine = try c.decodeIfPresent(String.self, forKey: .engine)
        engine = rawEngine.flatMap(ProxyEngine.init(rawValue:)) ?? .builtIn
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

    /// Marker command for the built-in engine. `RoutingCommandRunner` dispatches on this prefix;
    /// no shell ever parses the string, so the path after `-C ` is verbatim, not quoted.
    static let builtInCommandPrefix = "devdeck:proxy-listen -C "

    /// The synthetic daemon `Command` fed to `ProcessManager`, per engine.
    /// nil only for `.gost` without an installed binary (→ the UI warns, nothing starts).
    ///
    /// Both engines point at the generated 0600 config file rather than carrying credentials:
    /// gost v3 `auto://` used to take them in the listener spec — `gost -L 'auto://user:pass@:9999'`
    /// — which put the password in the process's argv, and macOS lets **every** local account read
    /// the full argv of every process, root's included. So the whole service definition moves into
    /// the config file and the command line carries nothing but its path.
    ///
    /// A second problem disappears with it: the password no longer passes through a shell string,
    /// so a quote in it can no longer close the literal and run the remainder as commands.
    ///
    /// The gost string is also stable across a password change now, where it used to differ. That
    /// does NOT yet buy orphan adoption for this daemon: `findOrphan` matches a pre-shell command
    /// string against post-shell argv from `ps`, and the quotes here (needed — the config path can
    /// contain a space) never appear in argv. Adoption of the listener has therefore never worked,
    /// before this change or after it; a surviving gost surfaces as an occupied port instead.
    /// Recorded rather than fixed here, because the defect is in the matching, not in this string.
    /// (The built-in marker never matches `ps` argv either — correct, since an in-process listener
    /// cannot outlive the app.)
    ///
    /// `watchdogEnabled` is what gives the "listener keeps dying" problem its auto-restart.
    func toCommand(gostPath: String?, configPath: String) -> Command? {
        let commandLine: String
        switch engine {
        case .gost:
            guard let gostPath else { return nil }
            commandLine = "\(shellQuote(gostPath)) -C \(shellQuote(configPath))"
        case .builtIn:
            commandLine = Self.builtInCommandPrefix + configPath
        }
        return Command(
            id: Self.daemonID,
            name: engine == .builtIn ? L10n.proxyShareDaemonNameBuiltIn : L10n.proxyShareDaemonName,
            command: commandLine,
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

/// gost v3's config schema, only the slice we generate — plus one extension key of our own.
/// Verified against `gost -L 'auto://user:pass@:port' -O yaml`, which prints the canonical
/// config for a listener spec; the built-in engine reads the same file back.
struct GostConfig: Codable, Equatable {
    let services: [GostService]
    /// DevDeck extension, present only in the remote-proxy BRIDGE's generated config: the local
    /// SOCKS endpoint (`host:port`) the listener dials targets through. Never written into the
    /// share's config, so gost — which would ignore it anyway — never even sees the key.
    var upstreamSocks: String? = nil
}

struct GostService: Codable, Equatable {
    let name: String
    let addr: String
    let handler: GostHandler
    let listener: GostListener
}

struct GostHandler: Codable, Equatable {
    let type: String
    /// Absent for an open proxy — the key is omitted, not sent empty.
    let auth: GostAuth?
}

struct GostAuth: Codable, Equatable {
    let username: String
    let password: String
}

struct GostListener: Codable, Equatable {
    let type: String
}
