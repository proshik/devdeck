import Foundation
import Darwin

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
///
/// The write is deliberately raw POSIX rather than `Data.write(to:)` or
/// `FileManager.createFile(atPath:contents:attributes:)`. Both of those are atomic
/// write-then-rename: they create a sibling temp file (`proxy.env.sb-…`) at the default 0644,
/// fill it, and rename it over the target. For a file that can hold the proxy password in
/// plaintext that is two problems — the contents exist world-readable for the duration of the
/// write inside a directory anyone can traverse, and a crash mid-write strands that 0644 sibling
/// forever, since removal only ever unlinks `proxy.env` itself.
///
/// `open` + `fchmod` + `write` instead: one inode, never wider than 0600 (`O_CREAT`'s mode
/// argument is ignored when the file already exists, hence the explicit `fchmod` before any byte
/// is written), and no sibling to leak or strand. The trade-off accepted in exchange is that the
/// file is briefly truncated rather than swapped atomically — harmless here, because a torn read
/// only makes the `dp` helper refuse, which is the safe state.
///
/// `url` is injected so tests can assert the mode and the directory creation on a temp path
/// instead of the developer's real `~/.config`.
struct LiveProxyEnvFile: ProxyEnvFileWriting {
    static let defaultURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/devdeck/proxy.env")

    let url: URL

    init(url: URL = LiveProxyEnvFile.defaultURL) {
        self.url = url
    }

    func write(_ contents: String) {
        do {
            // 0700 as well: the directory holds a file that can carry a password, so nobody else
            // needs to be able to list or traverse it.
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            DiagnosticLog.shared.log("Proxy env file: could not create the directory — "
                + error.localizedDescription, level: .warn)
            return
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            DiagnosticLog.shared.log("Proxy env file: could not open \(url.path) — \(Self.errnoText())",
                                     level: .warn)
            return
        }
        defer { close(fd) }
        // Before any byte is written: an existing file keeps its own mode through O_CREAT, so a
        // 0644 file left by an older build (or by hand) must be tightened first, not after.
        guard fchmod(fd, 0o600) == 0 else {
            DiagnosticLog.shared.log("Proxy env file: could not set mode 0600 on \(url.path) — "
                + Self.errnoText(), level: .warn)
            return
        }
        let bytes = Data(contents.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        guard written == bytes.count else {
            DiagnosticLog.shared.log(
                "Proxy env file: wrote \(written) of \(bytes.count) bytes to \(url.path) — "
                    + Self.errnoText(), level: .warn)
            return
        }
    }

    func remove() {
        if unlink(url.path) == 0 { return }
        let code = errno
        if code == ENOENT { return }   // already gone — that IS the end state we wanted
        DiagnosticLog.shared.log("Proxy env file: could not remove \(url.path) — "
            + Self.errnoText(code), level: .warn)
    }

    private static func errnoText(_ code: Int32 = errno) -> String {
        String(cString: strerror(code)) + " (errno \(code))"
    }
}
