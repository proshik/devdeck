import Foundation

/// Contents of `~/.config/devdeck/proxy.env` — the handshake between DevDeck and the `dp` shell
/// helper. Pure.
///
/// Plain `KEY=value`, deliberately NOT `export` lines: the helper reads the two keys it wants
/// rather than `source`-ing the file, so a corrupted or tampered file cannot execute anything.
func proxyEnvFileContents(url: String, lanPrefix: String) -> String {
    """
    # Written by DevDeck — do not edit, regenerated when the active proxy changes.
    DEVDECK_PROXY_URL=\(url)
    DEVDECK_PROXY_LAN=\(lanPrefix)

    """
}

/// Maintains the file the terminal helper reads. Behind a protocol (probe pattern, like everything
/// else in this directory) so tests never touch the real `~/.config`.
protocol ProxyEnvFileWriting: Sendable {
    func write(_ contents: String)
    func remove()
}

/// The real file at `~/.config/devdeck/proxy.env`, owner-readable only.
struct LiveProxyEnvFile: ProxyEnvFileWriting {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/devdeck/proxy.env")

    init() {}

    func write(_ contents: String) {
        let url = Self.url
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
        } catch {
            DiagnosticLog.shared.log("Proxy env file: could not create the directory — "
                + error.localizedDescription, level: .warn)
            return
        }
        // createFile (not an atomic write-then-rename) so the mode is set AT creation: this file can
        // carry the proxy password, and an atomic write would briefly leave it world-readable.
        // It's small and rewritten whole, and a torn read only makes the helper refuse — the safe way.
        let ok = FileManager.default.createFile(atPath: url.path, contents: Data(contents.utf8),
                                                attributes: [.posixPermissions: 0o600])
        if !ok {
            DiagnosticLog.shared.log("Proxy env file: write failed at \(url.path)", level: .warn)
        }
    }

    func remove() {
        try? FileManager.default.removeItem(at: Self.url)
    }
}
