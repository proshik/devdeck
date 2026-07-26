import Foundation
import Darwin

/// Everything DevDeck persists outside its own bundle, and the one place that decides who may
/// read it.
///
/// The rule is uniform: **0600 for files, 0700 for the directories holding them.** It is not
/// paranoia about the owner's own account — it is about the *other* accounts on the Mac. `ps` on
/// macOS shows every user the full argv of every process, so the machine is not a single trust
/// domain, and `~/Library/Application Support/DevDeck` holds a description of every command this
/// user runs, where it runs, and which proxy it dials. Older builds left that at 0644 in a 0755
/// directory while taking great care over `proxy.env` — the same class of data, two different
/// answers.
///
/// `restrict` and `makeDirectory` therefore tighten what already exists rather than only setting a
/// mode at creation time: the fix has to reach installs created before it shipped, and those are
/// the majority.
enum PrivateFile {
    /// Readable and writable by the owner only.
    static let fileMode = 0o600
    /// Listable and traversable by the owner only.
    static let directoryMode = 0o700

    /// `~/Library/Application Support/DevDeck` — the config, the log and the generated gost config.
    static var applicationSupportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DevDeck")
    }

    /// Create the directory if it is missing, and tighten it to 0700 either way.
    ///
    /// `createDirectory(attributes:)` only applies the mode to directories it actually creates, so
    /// the explicit `setAttributes` afterwards is what migrates a 0755 directory left by an older
    /// build. Throws only when the directory cannot be created — a failure to tighten is logged and
    /// swallowed, because refusing to save a config over it would be a worse outcome than a
    /// directory that stayed readable.
    static func makeDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: directoryMode]
        )
        setMode(directoryMode, at: url, kind: "directory")
    }

    /// Tighten an existing file to 0600. A missing file is not an error — callers use this right
    /// after a write, and on paths that may legitimately not exist yet.
    static func restrict(_ url: URL) {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        setMode(fileMode, at: url, kind: "file")
    }

    private static func setMode(_ mode: Int, at url: URL, kind: String) {
        do {
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        } catch {
            DiagnosticLog.shared.log(
                "Could not set mode \(String(mode, radix: 8)) on \(kind) \(url.path) — "
                    + error.localizedDescription, level: .warn)
        }
    }
}

// MARK: - Probe

/// Maintains a single owner-only file whose entire contents DevDeck owns and rewrites.
///
/// Behind a protocol (probe pattern, like the rest of `DevDeck/Proxy/`) so tests never touch the
/// real `~/.config` or `~/Library`. Used for `proxy.env` (the terminal helper's handshake) and for
/// the generated `gost.json` (the proxy listener's credentials).
///
/// Both operations report success, and the caller must not update its cache unless they succeed:
/// silently believing a removal happened would leave a file that grants proxy access — and carries
/// the password — in place forever, with nothing to retry it. The failure modes are real (a full
/// disk, a read-only home, an unwritable directory) and these files are a security control.
protocol PrivateFileWriting: Sendable {
    /// Where it lives. Part of the protocol because callers need the path as well as the writes —
    /// the gost config's path goes on the listener's command line — and a separately injected path
    /// could drift from the file actually being written.
    var url: URL { get }
    /// True when the file now holds exactly `contents`.
    func write(_ contents: String) -> Bool
    /// True when the file is gone. Already absent counts — that is the end state we wanted.
    func remove() -> Bool
}

/// The real file, owner-readable only.
///
/// The write is deliberately raw POSIX rather than `Data.write(to:)` or
/// `FileManager.createFile(atPath:contents:attributes:)`. `FileManager.createFile` — like
/// `Data.write(to:options: .atomic)` — is atomic write-then-rename: it creates a sibling temp
/// file (`proxy.env.sb-…`) at the default 0644, fills it, and renames it over the target. For a
/// file that can hold a password in plaintext that is two problems — the contents exist
/// world-readable for the duration of the write inside a directory anyone can traverse, and a
/// crash mid-write strands that 0644 sibling forever, since removal only ever unlinks the target
/// itself. Plain `Data.write(to:)` (no `.atomic` option) doesn't have that problem — it writes in
/// place, preserving the inode, so there's no sibling to strand — but on creation it still lands at
/// the default 0644, so a fresh file is briefly world-readable before this code gets a chance to
/// tighten it.
///
/// `open` + `fchmod` + `write` instead: one inode, never wider than 0600 (`O_CREAT`'s mode
/// argument is ignored when the file already exists, hence the explicit `fchmod` before any byte
/// is written), and no sibling to leak or strand. The trade-off accepted in exchange is that the
/// file is briefly truncated rather than swapped atomically — harmless for both current users,
/// because a torn read only makes the reader refuse, which is the safe state.
///
/// `url` is injected so tests can assert the mode and the directory creation on a temp path
/// instead of the developer's real home.
struct LivePrivateFile: PrivateFileWriting {
    let url: URL

    init(url: URL) {
        self.url = url
    }

    func write(_ contents: String) -> Bool {
        do {
            try PrivateFile.makeDirectory(at: url.deletingLastPathComponent())
        } catch {
            DiagnosticLog.shared.log("Private file: could not create the directory for \(url.path) — "
                + error.localizedDescription, level: .warn)
            return false
        }
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, mode_t(PrivateFile.fileMode))
        guard fd >= 0 else {
            // errno is captured before anything else can clobber it — likewise below.
            let code = errno
            DiagnosticLog.shared.log("Private file: could not open \(url.path) — \(Self.errnoText(code))",
                                     level: .warn)
            return false
        }
        defer { close(fd) }
        // Before any byte is written: an existing file keeps its own mode through O_CREAT, so a
        // 0644 file left by an older build (or by hand) must be tightened first, not after.
        guard fchmod(fd, mode_t(PrivateFile.fileMode)) == 0 else {
            let code = errno
            DiagnosticLog.shared.log("Private file: could not set mode 0600 on \(url.path) — "
                + Self.errnoText(code), level: .warn)
            return false
        }
        let bytes = Data(contents.utf8)
        let written = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        let writeErrno = errno
        guard written == bytes.count else {
            DiagnosticLog.shared.log(
                "Private file: wrote \(written) of \(bytes.count) bytes to \(url.path) — "
                    + Self.errnoText(writeErrno), level: .warn)
            return false
        }
        return true
    }

    func remove() -> Bool {
        if unlink(url.path) == 0 { return true }
        let code = errno
        if code == ENOENT { return true }   // already gone — that IS the end state we wanted
        DiagnosticLog.shared.log("Private file: could not remove \(url.path) — "
            + Self.errnoText(code), level: .warn)
        return false
    }

    private static func errnoText(_ code: Int32) -> String {
        String(cString: strerror(code)) + " (errno \(code))"
    }
}
