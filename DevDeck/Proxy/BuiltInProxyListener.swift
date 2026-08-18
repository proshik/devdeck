import Foundation
import Network

/// The in-process share listener: HTTP CONNECT + absolute-form forwarding on one port.
///
/// Event contract mirrors a gost PROCESS so `ProcessManager` cannot tell them apart:
/// `.started(pid: nil)` at start (before the bind, like a spawned gost — the exit-IP probe's
/// retry loop exists for exactly this window), gost-shaped session `.line`s on stderr,
/// `.terminated(1)` on a bind failure, `.terminated(0)` after `stop()`. Exactly one terminal
/// event ever, and nothing after it.
///
/// Everything — the listener and every connection — runs on one serial queue: no throughput
/// concern for LAN sharing, and no cross-connection locking to get wrong.
final class BuiltInProxyListener: @unchecked Sendable {

    /// Bound port once the listener is ready (an ephemeral 0 resolves to the real one).
    var boundPort: UInt16? { lock.lock(); defer { lock.unlock() }; return _boundPort }

    private let queue = DispatchQueue(label: "devdeck.proxy.builtin")
    private let lock = NSLock()
    private let requestedPort: UInt16
    private let auth: GostAuth?
    private let emit: @Sendable (RunnerOutput) -> Void
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]
    private var _boundPort: UInt16?
    private var terminated = false

    /// How long a dial to the target may sit unconnected before the client gets a 502.
    static let dialTimeout: TimeInterval = 15

    init(port: UInt16, auth: GostAuth?, emit: @escaping @Sendable (RunnerOutput) -> Void) {
        self.requestedPort = port
        self.auth = auth
        self.emit = emit
    }

    func start() {
        send(.started(pid: nil))
        queue.async { self.bind() }
    }

    /// Idempotent. The close lines of still-open sessions are deliberately NOT flushed — the
    /// terminal event ends the stream, exactly like SIGTERM ends a gost that never got to log.
    ///
    /// The terminal event is emitted from the `.cancelled` state, NOT here: `cancel()` closes the
    /// socket asynchronously, and a `.terminated` sent while the port is still held invites the
    /// next start (the `saveShare` restart cycle) to bind against our own not-yet-closed socket.
    func stop() {
        queue.async {
            for connection in self.connections.values { connection.cancel() }
            self.connections.removeAll()
            guard let listener = self.listener else {
                self.send(.terminated(exitCode: 0))   // never bound — nothing to wait for
                return
            }
            listener.cancel()
        }
    }

    // MARK: - Listener

    private func bind() {
        let listener: NWListener
        do {
            // SO_REUSEADDR, like every real server (gost included): without it, the previous
            // listener's just-died sessions sit in TIME_WAIT on this port and every bind for the
            // next ~30s gets EADDRINUSE — which is exactly the restart cycle (`saveShare` →
            // stop → start, or a watchdog restart) and the gost→built-in upgrade path. Found the
            // hard way on 2026-08-18: the watchdog burned all 3 restarts against TIME_WAIT
            // remnants and gave up. An ACTIVELY listening occupant still fails the bind — reuse
            // does not stack on a live listener — so the occupied-port machinery keeps its signal
            // (asserted by testOccupiedPortEmitsTerminated1).
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            if requestedPort == 0 {
                listener = try NWListener(using: params)
            } else {
                listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: requestedPort)!)
            }
        } catch {
            send(.line("built-in proxy: cannot listen on port \(requestedPort): \(error.localizedDescription)",
                       stream: .stderr))
            send(.terminated(exitCode: 1))
            return
        }
        self.listener = listener
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.lock.lock()
                self._boundPort = listener.port?.rawValue
                self.lock.unlock()
            case .failed(let error):
                self.send(.line("built-in proxy: listener failed: \(error.localizedDescription)",
                                stream: .stderr))
                listener.cancel()
                self.send(.terminated(exitCode: 1))
            case .cancelled:
                // The socket is actually closed now — the clean terminal for `stop()`. After a
                // `.failed` the once-guard in `send` has already spent the terminal event.
                self.send(.terminated(exitCode: 0))
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { connection.cancel(); return }
            let port = { [weak self] in Int(self?.boundPort ?? self?.requestedPort ?? 0) }
            let proxied = ProxyConnection(
                connection: connection,
                auth: self.auth,
                queue: self.queue,
                listenPort: port,
                emitLine: { [weak self] line in self?.send(.line(line, stream: .stderr)) },
                onFinish: { [weak self] finished in
                    self?.connections[ObjectIdentifier(finished)] = nil
                }
            )
            self.connections[ObjectIdentifier(proxied)] = proxied
            proxied.start()
        }
        listener.start(queue: queue)
    }

    /// Single gate for every event: nothing is emitted after the (single) terminal event, no
    /// matter which callback races it — the `RunnerOutput` stream invariant depends on this.
    private func send(_ event: RunnerOutput) {
        lock.lock()
        let dead = terminated
        if case .terminated = event { terminated = true }
        lock.unlock()
        guard !dead else { return }
        emit(event)
    }
}

// MARK: - One proxied connection

/// One accepted client connection: read the head, enforce auth, dial the target, pump bytes.
/// Runs entirely on the listener's serial queue.
private final class ProxyConnection {
    private let connection: NWConnection
    private let auth: GostAuth?
    private let queue: DispatchQueue
    private let listenPort: () -> Int
    private let emitLine: (String) -> Void
    private let onFinish: (ProxyConnection) -> Void

    private var buffer = Data()
    private var target: NWConnection?
    private var sessionOpen = false
    private var closed = false
    private var targetReady = false
    /// Short like gost's own sids; uniqueness only needs to hold within one listener's lifetime.
    private let sid = String(UUID().uuidString.prefix(13)).lowercased()
    private let client: String

    init(connection: NWConnection, auth: GostAuth?, queue: DispatchQueue,
         listenPort: @escaping () -> Int, emitLine: @escaping (String) -> Void,
         onFinish: @escaping (ProxyConnection) -> Void) {
        self.connection = connection
        self.auth = auth
        self.queue = queue
        self.listenPort = listenPort
        self.emitLine = emitLine
        self.onFinish = onFinish
        self.client = Self.describe(connection.endpoint)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            if case .failed = state { self?.close() }
        }
        connection.start(queue: queue)
        readHead()
    }

    func cancel() { close() }

    // MARK: Head

    private func readHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data { self.buffer.append(data) }
            if let range = self.buffer.range(of: httpHeadTerminator) {
                let head = self.buffer.subdata(in: self.buffer.startIndex..<range.lowerBound)
                let remainder = self.buffer.subdata(in: range.upperBound..<self.buffer.endIndex)
                self.buffer = Data()
                self.handleHead(head, remainder: remainder)
            } else if self.buffer.count > httpMaxHeadBytes {
                self.replyAndClose(proxyResponse400())
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.readHead()
            }
        }
    }

    private func handleHead(_ headData: Data, remainder: Data) {
        guard let head = parseHTTPRequestHead(headData) else {
            return replyAndClose(proxyResponse400())
        }
        if let auth, !proxyAuthorized(head, username: auth.username, password: auth.password) {
            // An unauthorized probe is not a session — no line, nothing for the client list.
            return replyAndClose(proxyResponse407())
        }
        switch classifyProxyRequest(head) {
        case .bad:
            replyAndClose(proxyResponse400())
        case .connect(let host, let port):
            openSession()
            dial(host: host, port: port) { [weak self] in
                guard let self else { return }
                // 200 first, then whatever the client optimistically sent after the head
                // (typically the TLS ClientHello) goes down the fresh tunnel.
                self.connection.send(content: proxyResponse200(), completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil else { self?.close(); return }
                    self.forwardToTarget(remainder)
                    self.startPumps()
                })
            }
        case .absoluteForm(let host, let port, let rewrittenHead):
            openSession()
            dial(host: host, port: port) { [weak self] in
                guard let self else { return }
                self.forwardToTarget(rewrittenHead + remainder)
                self.startPumps()
            }
        }
    }

    // MARK: Target

    private func dial(host: String, port: Int, onReady: @escaping () -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else {
            return replyAndClose(proxyResponse502())
        }
        let target = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.target = target
        target.stateUpdateHandler = { [weak self] state in
            guard let self, !self.closed else { return }
            switch state {
            case .ready:
                self.targetReady = true
                onReady()
            case .failed:
                self.replyAndClose(proxyResponse502())
            default:
                break
            }
        }
        target.start(queue: queue)
        // A dial into a silently-dropping network sits in .waiting forever — bound it.
        queue.asyncAfter(deadline: .now() + BuiltInProxyListener.dialTimeout) { [weak self] in
            guard let self, !self.closed, !self.targetReady else { return }
            self.replyAndClose(proxyResponse502())
        }
    }

    private func forwardToTarget(_ data: Data) {
        guard !data.isEmpty else { return }
        target?.send(content: data, completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    private func startPumps() {
        guard let target else { return close() }
        pump(from: connection, to: target)
        pump(from: target, to: connection)
    }

    /// One direction of the tunnel. Receive → send → receive again, so the send completion is
    /// the backpressure. EOF or an error on either side tears the whole tunnel down.
    private func pump(from source: NWConnection, to sink: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let data, !data.isEmpty {
                sink.send(content: data, completion: .contentProcessed { [weak self] sendError in
                    guard let self, !self.closed else { return }
                    if sendError != nil || isComplete || error != nil {
                        self.close()
                    } else {
                        self.pump(from: source, to: sink)
                    }
                })
            } else if isComplete || error != nil {
                self.close()
            } else {
                self.pump(from: source, to: sink)
            }
        }
    }

    // MARK: Session accounting

    private func openSession() {
        sessionOpen = true
        emitLine(builtInSessionLine(open: true, client: client, sid: sid, port: listenPort()))
    }

    private func replyAndClose(_ response: Data) {
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            self?.close()
        })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        connection.cancel()
        target?.cancel()
        if sessionOpen {
            emitLine(builtInSessionLine(open: false, client: client, sid: sid, port: listenPort()))
        }
        onFinish(self)
    }

    /// The peer as "IP:port", IPv6 bracketed — the same shape gost reports, which is what
    /// `proxyClientIP` on the monitor side expects to split.
    private static func describe(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, let port) = endpoint else { return "unknown:0" }
        switch host {
        case .ipv4(let address): return "\(address):\(port)"
        case .ipv6(let address): return "[\(address)]:\(port)"
        case .name(let name, _): return "\(name):\(port)"
        @unknown default: return "unknown:0"
        }
    }
}
