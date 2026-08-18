import Foundation

/// The slice of the generated `gost.json` the built-in engine starts from: the first service's
/// port and optional auth. Pure — nil on anything unexpected, and the runner then fails the run
/// loudly (same shape as `gost -C` on a broken file).
func parseBuiltInProxyConfig(_ data: Data) -> (port: Int, auth: GostAuth?)? {
    guard let config = try? JSONDecoder().decode(GostConfig.self, from: data),
          let service = config.services.first else { return nil }
    // addr is ":PORT" as generated; tolerate a host prefix by taking the last colon's suffix.
    guard let colon = service.addr.lastIndex(of: ":"),
          let port = Int(service.addr[service.addr.index(after: colon)...]),
          port >= 0 else { return nil }
    return (port, service.handler.auth)
}
