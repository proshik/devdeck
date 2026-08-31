import Foundation

/// A client-side proxy reached over an SSH tunnel to a VDS — the "no second Mac" egress.
///
/// Nothing runs on the VDS beyond `sshd`: the Mac holds `ssh -N -D 127.0.0.1:<socksPort>` (the
/// tunnel command, a regular visible deck command this struct only references) and a local
/// **bridge** — the built-in engine with a SOCKS upstream — that presents the tunnel as plain
/// `http://127.0.0.1:<localPort>` to every existing consumer (env injection, `dp`, the browser
/// button, the check probe).
///
/// No auth by design: the entry point is loopback, authentication is the ssh key.
/// Decoding is resilient: every key falls back to its default.
struct RemoteProxy: Codable, Equatable, Identifiable {
    var id: UUID
    /// What the proxy list shows; independent of Bonjour names.
    var name: String
    /// The bridge's HTTP port on this Mac.
    var localPort: Int
    /// `ssh -D`'s SOCKS port on this Mac.
    var socksPort: Int
    /// The ssh daemon command created for (or assigned to) this proxy. nil → permanently
    /// unusable until re-linked (the editor shows which command is missing).
    var tunnelCommandID: UUID?

    init(id: UUID = UUID(), name: String = "", localPort: Int = 18888, socksPort: Int = 1080,
         tunnelCommandID: UUID? = nil) {
        self.id = id
        self.name = name
        self.localPort = localPort
        self.socksPort = socksPort
        self.tunnelCommandID = tunnelCommandID
    }

    enum CodingKeys: String, CodingKey {
        case id, name, localPort, socksPort, tunnelCommandID
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        localPort = try c.decodeIfPresent(Int.self, forKey: .localPort) ?? 18888
        socksPort = try c.decodeIfPresent(Int.self, forKey: .socksPort) ?? 1080
        tunnelCommandID = try c.decodeIfPresent(UUID.self, forKey: .tunnelCommandID)
    }

    /// Stable id for the synthetic bridge daemon — same reasoning as `ProxyShare.daemonID`.
    static let bridgeDaemonID = UUID(uuidString: "6057D9E0-0000-4000-8000-000000000002")!

    /// Where the generated bridge config lives — beside `gost.json`, same 0600 discipline.
    static var bridgeConfigURL: URL {
        PrivateFile.applicationSupportDirectory.appendingPathComponent("proxy-bridge.json")
    }

    /// The ssh tunnel as a REGULAR deck command — created once by the add flow, then owned and
    /// editable by the user like any other daemon (`-J jumphost`, options — their business).
    /// `-N` (no remote command) + `-D` (dynamic SOCKS on loopback): the VDS needs nothing but sshd.
    ///
    /// A fresh id on every call — this is a factory for the creation flow, not a stable mapping;
    /// the link that persists is `tunnelCommandID`.
    func makeTunnelCommand(destination: String) -> Command {
        Command(
            name: L10n.proxyTunnelCommandName(name),
            command: Self.tunnelCommandString(destination: destination, socksPort: socksPort),
            isDaemon: true,
            watchdogEnabled: true,
            port: socksPort
        )
    }

    /// The generated shape of the tunnel command's `command` string — the single source both
    /// `makeTunnelCommand` and `TunnelCommandUpdate` build from and check against, so the
    /// generator and the "was this hand-edited?" parser can never drift apart.
    static func tunnelCommandString(destination: String, socksPort: Int) -> String {
        "ssh -N -D 127.0.0.1:\(socksPort) \(destination)"
    }

    /// Recover the destination a tunnel command was generated from — how the edit sheet prefills
    /// its destination field. nil when `command` does not start with the expected prefix at
    /// `socksPort`: the command was edited by hand beyond the destination suffix (a jump host, an
    /// identity file, reordered flags…), or predates this field, and can't be parsed reliably.
    static func parsedDestination(fromTunnelCommand command: String, socksPort: Int) -> String? {
        let prefix = tunnelCommandString(destination: "", socksPort: socksPort)
        guard command.hasPrefix(prefix) else { return nil }
        return String(command.dropFirst(prefix.count))
    }

    /// The synthetic bridge daemon: the built-in engine with a SOCKS upstream, expressed through
    /// the SAME marker command as the share's listener — `RoutingCommandRunner` needs no new case.
    func bridgeCommand(configPath: String) -> Command {
        Command(
            id: Self.bridgeDaemonID,
            name: L10n.proxyBridgeDaemonName,
            command: ProxyShare.builtInCommandPrefix + configPath,
            isDaemon: true,
            watchdogEnabled: true,
            port: localPort
        )
    }
}
