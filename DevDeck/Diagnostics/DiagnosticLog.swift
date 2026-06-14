import Foundation
import Darwin

/// Thread-safe file log + crash capture. Writes to
/// `~/Library/Application Support/DevDeck/devdeck.log` (alongside the config).
/// So that when "the app closed" there is a record of what happened.
final class DiagnosticLog: @unchecked Sendable {
    enum Level: String { case info = "INFO", warn = "WARN", error = "ERROR" }

    let fileURL: URL
    private let maxBytes: Int
    private let lock = NSLock()
    private var handle: FileHandle?
    private var bytesWritten = 0
    private let formatter: DateFormatter

    static let shared = DiagnosticLog(fileURL: DiagnosticLog.defaultURL)

    nonisolated static var defaultURL: URL {
        // Under XCTest — use a temp directory so tests don't pollute the real app log
        // (tests run in the same app bundle and call DiagnosticLog.shared).
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("DevDeck-test/devdeck.log")
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DevDeck/devdeck.log")
    }

    init(fileURL: URL, maxBytes: Int = 512 * 1024) {
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        self.formatter = formatter

        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        openHandle(rotatingIfOver: maxBytes)
    }

    func log(_ message: String, level: Level = .info) {
        lock.lock()
        defer { lock.unlock() }
        let line = "\(formatter.string(from: Date())) [\(level.rawValue)] \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        try? handle?.write(contentsOf: data)
        bytesWritten += data.count
        if bytesWritten > maxBytes { rotate() }   // rotation WITHIN a session, not only at startup
    }

    // MARK: rotation / opening (under lock or in init)

    private func openHandle(rotatingIfOver cap: Int) {
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: fileURL.path),
           let size = attrs[.size] as? Int, size > cap {
            moveToBackup()
        }
        if !fm.fileExists(atPath: fileURL.path) {
            fm.createFile(atPath: fileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: fileURL)
        if let handle, let end = try? handle.seekToEnd() {
            bytesWritten = Int(end)
        } else {
            bytesWritten = 0
        }
    }

    private func rotate() {
        try? handle?.close()
        moveToBackup()
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: fileURL)
        bytesWritten = 0
    }

    private func moveToBackup() {
        let fm = FileManager.default
        let backup = fileURL.appendingPathExtension("1")   // devdeck.log.1 (single backup)
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: fileURL, to: backup)
    }

    // MARK: crash capture

    /// Install handlers for uncaught exceptions and fatal signals. Idempotent.
    /// Best-effort: Swift `fatalError`/precondition are caught partially (via SIGTRAP/SIGILL).
    func installCrashHandlers() {
        guard diagnosticLogFD < 0 else { return }   // already installed — don't create extra fds
        diagnosticLogFD = open(fileURL.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)

        NSSetUncaughtExceptionHandler { exception in
            DiagnosticLog.shared.log(
                "UNCAUGHT EXCEPTION: \(exception.name.rawValue) — \(exception.reason ?? "")\n"
                    + exception.callStackSymbols.joined(separator: "\n"),
                level: .error
            )
        }

        for sig in [SIGABRT, SIGSEGV, SIGILL, SIGTRAP, SIGBUS, SIGFPE] {
            signal(sig, diagnosticSignalHandler)
        }
    }
}

// MARK: signal handler (outside the class: requires a C-compatible function and global state)

private var diagnosticLogFD: Int32 = -1
private var crashBacktrace = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
private var diagnosticInHandler: sig_atomic_t = 0

/// Async-signal-safe(-ish): writes a marker + backtrace directly to the open fd, without Foundation.
private func diagnosticSignalHandler(_ sig: Int32) {
    if diagnosticInHandler != 0 {   // guard against re-entry / concurrent crashes
        signal(sig, SIG_DFL)
        raise(sig)
        return
    }
    diagnosticInHandler = 1

    let fd = diagnosticLogFD
    if fd >= 0 {
        let marker = "\n--- CRASH: fatal signal ---\n"
        _ = marker.withCString { write(fd, $0, strlen($0)) }
        let count = backtrace(&crashBacktrace, Int32(crashBacktrace.count))
        backtrace_symbols_fd(&crashBacktrace, count, fd)
    }
    signal(sig, SIG_DFL)
    raise(sig)
}
