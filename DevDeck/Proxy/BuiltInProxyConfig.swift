import Foundation

/// The slice of the generated config the built-in engine starts from: the first service's port,
/// optional auth, and — for the remote-proxy bridge — the optional SOCKS upstream. Pure — nil on
/// anything unexpected, and the runner then fails the run loudly (same shape as `gost -C` on a
/// broken file).
func parseBuiltInProxyConfig(_ data: Data) -> (port: Int, auth: GostAuth?, upstreamSocks: String?)? {
    guard let config = try? JSONDecoder().decode(GostConfig.self, from: data),
          let service = config.services.first else { return nil }
    // addr is ":PORT" as generated; tolerate a host prefix by taking the last colon's suffix.
    guard let colon = service.addr.lastIndex(of: ":"),
          let port = Int(service.addr[service.addr.index(after: colon)...]),
          port >= 0 else { return nil }
    return (port, service.handler.auth, config.upstreamSocks)
}

/// The remote-proxy bridge's generated config, as JSON. Pure; sorted keys for determinism.
///
/// Same schema as the share's `gost.json` plus the `upstreamSocks` extension — one writer/reader
/// pair for both engines' files. No auth by design: the bridge is loopback-only, authentication
/// is the ssh key that holds the tunnel.
func bridgeConfigJSON(localPort: Int, socksPort: Int) -> String? {
    let config = GostConfig(
        services: [
            GostService(
                name: "devdeck-bridge",
                addr: ":\(localPort)",
                handler: GostHandler(type: "auto", auth: nil),
                listener: GostListener(type: "tcp")
            )
        ],
        upstreamSocks: "127.0.0.1:\(socksPort)"
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(config) else {
        DiagnosticLog.shared.log("Remote proxy: could not encode the bridge config", level: .error)
        return nil
    }
    return String(decoding: data, as: UTF8.self)
}
