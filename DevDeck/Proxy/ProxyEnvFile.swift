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
///
/// Both operations report success, and the caller must not update its cache unless they succeed:
/// silently believing a removal happened would leave a file that grants proxy access — and carries
/// the password — in place forever, with nothing to retry it. The failure modes are real (a full
/// disk, a read-only home, an unwritable directory) and this file is a security control.
protocol ProxyEnvFileWriting: Sendable {
    /// True when the file now holds exactly `contents`.
    func write(_ contents: String) -> Bool
    /// True when the file is gone. Already absent counts — that is the end state we wanted.
    func remove() -> Bool
}

/// The real file at `~/.config/devdeck/proxy.env`, owner-readable only.
///
/// The write is deliberately raw POSIX rather than `Data.write(to:)` or
/// `FileManager.createFile(atPath:contents:attributes:)`. `FileManager.createFile` — like
/// `Data.write(to:options: .atomic)` — is atomic write-then-rename: it creates a sibling temp
/// file (`proxy.env.sb-…`) at the default 0644, fills it, and renames it over the target. For a
/// file that can hold the proxy password in plaintext that is two problems — the contents exist
/// world-readable for the duration of the write inside a directory anyone can traverse, and a
/// crash mid-write strands that 0644 sibling forever, since removal only ever unlinks
/// `proxy.env` itself. Plain `Data.write(to:)` (no `.atomic` option) doesn't have that problem —
/// it writes in place, preserving the inode, so there's no sibling to strand — but on creation it
/// still lands at the default 0644, so a fresh file is briefly world-readable before this code
/// gets a chance to tighten it.
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

    func write(_ contents: String) -> Bool {
        do {
            // 0700 as well: the directory holds a file that can carry a password, so nobody else
            // needs to be able to list or traverse it.
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            DiagnosticLog.shared.log("Proxy env file: could not create the directory — "
                + error.localizedDescription, level: .warn)
            return false
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else {
            // errno is captured before anything else can clobber it — likewise below.
            let code = errno
            DiagnosticLog.shared.log("Proxy env file: could not open \(url.path) — \(Self.errnoText(code))",
                                     level: .warn)
            return false
        }
        defer { close(fd) }
        // Before any byte is written: an existing file keeps its own mode through O_CREAT, so a
        // 0644 file left by an older build (or by hand) must be tightened first, not after.
        guard fchmod(fd, 0o600) == 0 else {
            let code = errno
            DiagnosticLog.shared.log("Proxy env file: could not set mode 0600 on \(url.path) — "
                + Self.errnoText(code), level: .warn)
            return false
        }
        let bytes = Data(contents.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let writeErrno = errno
        guard written == bytes.count else {
            DiagnosticLog.shared.log(
                "Proxy env file: wrote \(written) of \(bytes.count) bytes to \(url.path) — "
                    + Self.errnoText(writeErrno), level: .warn)
            return false
        }
        return true
    }

    func remove() -> Bool {
        if unlink(url.path) == 0 { return true }
        let code = errno
        if code == ENOENT { return true }   // already gone — that IS the end state we wanted
        DiagnosticLog.shared.log("Proxy env file: could not remove \(url.path) — "
            + Self.errnoText(code), level: .warn)
        return false
    }

    private static func errnoText(_ code: Int32) -> String {
        String(cString: strerror(code)) + " (errno \(code))"
    }
}
