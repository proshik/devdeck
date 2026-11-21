import Darwin
import Foundation

/// Why the app could not start listening for the command line.
enum AutomationSocketError: Error, Equatable {
    /// The socket path does not fit `sun_path`.
    case pathTooLong
    /// Another DevDeck already answers on this socket — it is not taken over.
    case alreadyServing
    /// Something that is not a socket sits at the path; it is left alone.
    case notASocket
    case system(String, Int32)
}

/// Listens on the automation socket of the running app. One connection carries one request line
/// and one response line. Protection: the directory is 0700, the socket 0600, and a peer whose
/// UID differs from ours is dropped before a byte is read. Requests are bounded in size and in
/// the time a peer may take to send one; a broken or foreign request is answered with an error
/// and never reaches the handler.
final class AutomationSocketServer: @unchecked Sendable {
    typealias Handler = @Sendable (AutomationRequest) async -> AutomationResponse

    private let socketURL: URL
    private let expectedUID: uid_t
    private let maxConnections: Int
    private let handler: Handler
    private let acceptQueue = DispatchQueue(label: "DevDeck.automation.accept")
    private let ioQueue = DispatchQueue(label: "DevDeck.automation.io", attributes: .concurrent)
    private let lock = NSLock()
    private var source: DispatchSourceRead?
    private var boundInode: ino_t?
    private var activeConnections = 0

    init(socketURL: URL, expectedUID: uid_t = getuid(), maxConnections: Int = 16, handler: @escaping Handler) {
        self.socketURL = socketURL
        self.expectedUID = expectedUID
        self.maxConnections = maxConnections
        self.handler = handler
    }

    var path: String { socketURL.path }

    func start() throws {
        guard var address = AutomationSocketAddress(path: path) else { throw AutomationSocketError.pathTooLong }
        try PrivateFile.makeDirectory(at: socketURL.deletingLastPathComponent())
        try removeStaleSocket()

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AutomationSocketError.system("socket", errno) }
        AutomationSocketIO.prepare(fd)
        guard address.withSockaddr({ bind(fd, $0, $1) }) == 0 else {
            let code = errno
            close(fd)
            throw code == EADDRINUSE ? AutomationSocketError.alreadyServing : AutomationSocketError.system("bind", code)
        }
        // The directory is already owner-only; this keeps the socket so even if it is moved.
        chmod(path, mode_t(PrivateFile.fileMode))
        guard listen(fd, 16) == 0, fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw AutomationSocketError.system("listen", code)
        }
        var info = stat()
        let inode: ino_t? = lstat(path, &info) == 0 ? info.st_ino : nil

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending(fd) }
        source.setCancelHandler { close(fd) }
        lock.lock()
        self.source = source
        boundInode = inode
        lock.unlock()
        source.resume()
    }

    /// Stop listening and remove the socket — only if it is still ours, not a successor's.
    /// Requests already accepted finish on their own.
    func stop() {
        lock.lock()
        let source = self.source
        let inode = boundInode
        self.source = nil
        boundInode = nil
        lock.unlock()
        guard let source else { return }
        source.cancel()
        var info = stat()
        if let inode, lstat(path, &info) == 0, info.st_ino == inode { unlink(path) }
    }

    /// A socket file without a listener is what a crashed app leaves; a live one is another
    /// instance and is not taken over; anything else at the path is not ours to delete.
    private func removeStaleSocket() throws {
        var info = stat()
        guard lstat(path, &info) == 0 else { return }
        guard info.st_mode & S_IFMT == S_IFSOCK else { throw AutomationSocketError.notASocket }
        let probe = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(probe) }
        AutomationSocketIO.prepare(probe)
        guard var address = AutomationSocketAddress(path: path) else { throw AutomationSocketError.pathTooLong }
        if address.withSockaddr({ connect(probe, $0, $1) }) == 0 { throw AutomationSocketError.alreadyServing }
        unlink(path)
    }

    private func acceptPending(_ listener: Int32) {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }   // EAGAIN: nothing more queued
            AutomationSocketIO.prepare(fd)
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
            lock.lock()
            let admitted = activeConnections < maxConnections
            if admitted { activeConnections += 1 }
            lock.unlock()
            guard admitted else { close(fd); continue }
            ioQueue.async { self.serve(fd) }
        }
    }

    private func serve(_ fd: Int32) {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == expectedUID else { return finish(fd) }
        AutomationSocketIO.setTimeouts(fd, receive: AutomationWire.requestReadTimeout, send: 10)

        let request: AutomationRequest
        switch AutomationSocketIO.readLine(fd, limit: AutomationWire.maxRequestBytes) {
        case .closed:
            return finish(fd)   // a probe or a client that gave up — nothing to answer
        case .tooLong, .failed:
            return reply(fd, AutomationResponse(exitCode: AutomationExitCode.communication, stdout: "",
                                                stderr: L10n.automationBadRequest))
        case .line(let data):
            guard let decoded = try? AutomationWire.decodeRequest(data) else {
                return reply(fd, AutomationResponse(exitCode: AutomationExitCode.communication, stdout: "",
                                                    stderr: L10n.automationBadRequest))
            }
            request = decoded
        }
        guard request.version == AutomationRequest.currentVersion else {
            return reply(fd, AutomationResponse(exitCode: AutomationExitCode.communication, stdout: "",
                                                stderr: L10n.automationVersionMismatch(request.version)))
        }
        let handler = self.handler
        Task {
            let response = await handler(request)
            self.ioQueue.async { self.reply(fd, response) }
        }
    }

    private func reply(_ fd: Int32, _ response: AutomationResponse) {
        if let data = try? AutomationWire.encode(response) { _ = AutomationSocketIO.writeAll(fd, data) }
        finish(fd)
    }

    private func finish(_ fd: Int32) {
        close(fd)
        lock.lock()
        activeConnections -= 1
        lock.unlock()
    }
}

/// The command line's side of the socket. Never starts DevDeck: no socket means not running.
enum AutomationSocketClient {
    enum Failure: Error, Equatable {
        case notRunning
        case communication(String)
    }

    static func send(_ request: AutomationRequest, socketURL: URL, expectedUID: uid_t = getuid(),
                     receiveTimeout: TimeInterval) -> Result<AutomationResponse, Failure> {
        guard var address = AutomationSocketAddress(path: socketURL.path) else {
            return .failure(.communication("socket path is longer than \(AutomationEndpoint.maxPathBytes) bytes: \(socketURL.path)"))
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .failure(.communication(AutomationSocketIO.describe(errno))) }
        defer { close(fd) }
        AutomationSocketIO.prepare(fd)
        guard address.withSockaddr({ connect(fd, $0, $1) }) == 0 else {
            let code = errno
            return [ENOENT, ECONNREFUSED, ENOTDIR].contains(code)
                ? .failure(.notRunning) : .failure(.communication(AutomationSocketIO.describe(code)))
        }
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == expectedUID else {
            return .failure(.communication("the socket belongs to another user"))
        }
        AutomationSocketIO.setTimeouts(fd, receive: receiveTimeout, send: 10)
        guard let data = try? AutomationWire.encode(request), AutomationSocketIO.writeAll(fd, data) else {
            return .failure(.communication(AutomationSocketIO.describe(errno)))
        }
        switch AutomationSocketIO.readLine(fd, limit: AutomationWire.maxResponseBytes) {
        case .line(let reply):
            guard let response = try? AutomationWire.decodeResponse(reply) else {
                return .failure(.communication("unreadable reply"))
            }
            guard response.version == AutomationRequest.currentVersion else {
                return .failure(.communication("reply uses protocol \(response.version)"))
            }
            return .success(response)
        case .closed:
            return .failure(.communication("connection closed without a reply"))
        case .tooLong:
            return .failure(.communication("reply is too large"))
        case .failed(let code):
            return .failure(.communication(code == EAGAIN || code == EWOULDBLOCK
                                           ? L10n.automationNoAnswer(Int(receiveTimeout.rounded(.up)))
                                           : AutomationSocketIO.describe(code)))
        }
    }
}

/// Blocking socket helpers shared by both ends.
enum AutomationSocketIO {
    enum ReadResult {
        case line(Data)
        /// EOF before any byte.
        case closed
        case tooLong
        case failed(Int32)
    }

    /// Not inherited by the commands DevDeck launches; no SIGPIPE when the peer has gone.
    static func prepare(_ fd: Int32) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    static func setTimeouts(_ fd: Int32, receive: TimeInterval, send: TimeInterval) {
        var r = timeval(receive)
        var s = timeval(send)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &r, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &s, socklen_t(MemoryLayout<timeval>.size))
    }

    /// Up to the first newline (or EOF after some bytes), at most `limit` bytes.
    static func readLine(_ fd: Int32, limit: Int) -> ReadResult {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                return .failed(errno)
            }
            if count == 0 { return data.isEmpty ? .closed : .line(data) }
            if let newline = buffer[0..<count].firstIndex(of: UInt8(ascii: "\n")) {
                data.append(contentsOf: buffer[0..<newline])
                return data.count > limit ? .tooLong : .line(data)
            }
            data.append(contentsOf: buffer[0..<count])
            if data.count > limit { return .tooLong }
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        data.withUnsafeBytes { raw in
            guard var pointer = raw.baseAddress else { return true }
            var remaining = raw.count
            while remaining > 0 {
                let written = write(fd, pointer, remaining)
                if written < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                remaining -= written
                pointer += written
            }
            return true
        }
    }

    static func describe(_ code: Int32) -> String {
        String(cString: strerror(code)) + " (errno \(code))"
    }
}

private extension timeval {
    init(_ interval: TimeInterval) {
        let whole = max(0, interval.rounded(.down))
        self.init(tv_sec: Int(whole), tv_usec: Int32((max(0, interval) - whole) * 1_000_000))
    }
}
