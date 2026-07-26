import Foundation

/// Contents of `~/.config/devdeck/proxy.env` — the handshake between DevDeck and the `dp` shell
/// helper. Pure.
///
/// Plain `KEY=value`, deliberately NOT `export` lines: the helper reads the two keys it wants
/// rather than `source`-ing the file, so a corrupted or tampered file cannot execute anything.
///
/// The file itself is written by `LivePrivateFile` — owner-only, like everything else DevDeck keeps
/// on disk.
func proxyEnvFileContents(url: String, lanPrefix: String) -> String {
    """
    # Written by DevDeck — do not edit, regenerated when the active proxy changes.
    DEVDECK_PROXY_URL=\(url)
    DEVDECK_PROXY_LAN=\(lanPrefix)

    """
}

/// Where the `dp` helper looks for it. Not under Application Support: the helper is a shell
/// function, and `~/.config` is where a shell expects to find its own configuration.
let proxyEnvFileURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".config/devdeck/proxy.env")
