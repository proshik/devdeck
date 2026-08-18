import XCTest
import Network
@testable import DevDeck

/// Loopback integration: a real NWListener, a real echo server, real bytes both ways.
/// Everything protocol-level is covered by HTTPProxyParserTests; this asserts the plumbing.
final class BuiltInProxyListenerTests: XCTestCase {

    /// Minimal TCP echo server on an ephemeral port; returns (listener to cancel, its port).
    private func startEchoServer() throws -> (NWListener, UInt16) {
        let listener = try NWListener(using: .tcp)
        listener.newConnectionHandler = { connection in
            connection.start(queue: .global())
            func pump() {
                connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, _ in
                    if let data, !data.isEmpty { connection.send(content: data, completion: .idempotent) }
                    if done { connection.cancel() } else { pump() }
                }
            }
            pump()
        }
        let ready = expectation(description: "echo ready")
        listener.stateUpdateHandler = { if case .ready = $0 { ready.fulfill() } }
        listener.start(queue: .global())
        wait(for: [ready], timeout: 5)
        return (listener, listener.port!.rawValue)
    }

    /// Collects emitted RunnerOutput events thread-safely.
    private final class EventSink: @unchecked Sendable {
        private let lock = NSLock()
        private var events: [RunnerOutput] = []
        func append(_ event: RunnerOutput) { lock.lock(); events.append(event); lock.unlock() }
        var snapshot: [RunnerOutput] { lock.lock(); defer { lock.unlock() }; return events }
    }

    func testConnectTunnelCarriesBytesBothWaysAndLogsTheSession() throws {
        let (echo, echoPort) = try startEchoServer()
        defer { echo.cancel() }

        let sink = EventSink()
        let started = expectation(description: "listener started")
        let proxy = BuiltInProxyListener(port: 0, auth: nil) { event in
            sink.append(event)
            if case .started = event { started.fulfill() }
        }
        proxy.start()
        wait(for: [started], timeout: 5)
        let proxyPort = try XCTUnwrap(awaitBoundPort(of: proxy))

        // Raw client: CONNECT to the echo server through the proxy, then echo a payload.
        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!, using: .tcp)
        let replied = expectation(description: "CONNECT accepted and payload echoed")
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let connect = "CONNECT 127.0.0.1:\(echoPort) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n"
            client.send(content: Data(connect.utf8), completion: .idempotent)
            client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let response = String(decoding: data ?? Data(), as: UTF8.self)
                XCTAssertTrue(response.hasPrefix("HTTP/1.1 200"), "got: \(response)")
                client.send(content: Data("ping-through-tunnel".utf8), completion: .idempotent)
                client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { echoed, _, _, _ in
                    XCTAssertEqual(String(decoding: echoed ?? Data(), as: UTF8.self), "ping-through-tunnel")
                    replied.fulfill()
                }
            }
        }
        client.start(queue: .global())
        wait(for: [replied], timeout: 10)
        client.cancel()

        // The open line must have been logged in the gost shape by now.
        let opened = sink.snapshot.contains { event in
            guard case .line(let text, .stderr) = event,
                  case .sessionOpened = parseGostLogLine(text) else { return false }
            return true
        }
        XCTAssertTrue(opened, "no gost-shaped session-open line; events: \(sink.snapshot)")

        proxy.stop()
        // stop() must produce exactly one clean terminal.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline,
              !sink.snapshot.contains(.terminated(exitCode: 0)) { usleep(50_000) }
        XCTAssertEqual(sink.snapshot.filter { if case .terminated = $0 { return true }; return false },
                       [.terminated(exitCode: 0)])
    }

    func testAuthRequiredGets407WithoutCredentials() throws {
        let sink = EventSink()
        let started = expectation(description: "started")
        let proxy = BuiltInProxyListener(port: 0, auth: GostAuth(username: "dev", password: "pw")) { event in
            sink.append(event)
            if case .started = event { started.fulfill() }
        }
        proxy.start()
        wait(for: [started], timeout: 5)
        defer { proxy.stop() }
        let proxyPort = try XCTUnwrap(awaitBoundPort(of: proxy))

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!, using: .tcp)
        let got407 = expectation(description: "407")
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.send(content: Data("CONNECT x:443 HTTP/1.1\r\n\r\n".utf8), completion: .idempotent)
            client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                XCTAssertTrue(String(decoding: data ?? Data(), as: UTF8.self).hasPrefix("HTTP/1.1 407"))
                got407.fulfill()
            }
        }
        client.start(queue: .global())
        wait(for: [got407], timeout: 10)
        client.cancel()
        // An unauthorized probe is NOT a session — nothing to show in the client list.
        XCTAssertFalse(sink.snapshot.contains { if case .line = $0 { return true }; return false })
    }

    func testAbsoluteFormIsRewrittenAndForwardedToTheOrigin() throws {
        // Mini origin: records what arrives, answers a fixed HTTP response.
        let recorded = NSMutableData()
        let origin = try NWListener(using: .tcp)
        origin.newConnectionHandler = { connection in
            connection.start(queue: .global())
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                if let data { recorded.append(data) }
                let response = "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nhi"
                connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
                    connection.cancel()
                })
            }
        }
        let originReady = expectation(description: "origin ready")
        origin.stateUpdateHandler = { if case .ready = $0 { originReady.fulfill() } }
        origin.start(queue: .global())
        wait(for: [originReady], timeout: 5)
        defer { origin.cancel() }
        let originPort = origin.port!.rawValue

        let started = expectation(description: "started")
        let proxy = BuiltInProxyListener(port: 0, auth: nil) { event in
            if case .started = event { started.fulfill() }
        }
        proxy.start()
        wait(for: [started], timeout: 5)
        defer { proxy.stop() }
        let proxyPort = try XCTUnwrap(awaitBoundPort(of: proxy))

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: proxyPort)!, using: .tcp)
        let answered = expectation(description: "origin response relayed")
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            let request = "GET http://127.0.0.1:\(originPort)/who HTTP/1.1\r\n"
                + "Host: 127.0.0.1\r\nProxy-Connection: keep-alive\r\n\r\n"
            client.send(content: Data(request.utf8), completion: .idempotent)
            client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                let response = String(decoding: data ?? Data(), as: UTF8.self)
                XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK"), "got: \(response)")
                XCTAssertTrue(response.hasSuffix("hi"))
                answered.fulfill()
            }
        }
        client.start(queue: .global())
        wait(for: [answered], timeout: 10)
        client.cancel()

        let seenByOrigin = String(decoding: recorded as Data, as: UTF8.self)
        XCTAssertTrue(seenByOrigin.hasPrefix("GET /who HTTP/1.1\r\n"),
                      "the origin must see origin-form, not the absolute-form target: \(seenByOrigin)")
        XCTAssertFalse(seenByOrigin.lowercased().contains("proxy-"),
                       "hop-by-hop proxy headers must have been stripped")
    }

    /// Regression (2026-08-18): the restart cycle — `saveShare` → stop → start, a watchdog
    /// restart, or the gost→built-in upgrade — rebinds the SAME port while the previous
    /// listener's just-closed sessions are still in TIME_WAIT. Without SO_REUSEADDR every such
    /// bind gets EADDRINUSE for ~30s and the watchdog burns all its restarts against it.
    func testRebindsThePortRightAfterAStopWithLiveSessions() throws {
        let (echo, echoPort) = try startEchoServer()
        defer { echo.cancel() }

        // First listener: take a fixed ephemeral port, run one real session through it.
        let firstStarted = expectation(description: "first started")
        let firstStopped = expectation(description: "first stopped")
        let first = BuiltInProxyListener(port: 0, auth: nil) { event in
            if case .started = event { firstStarted.fulfill() }
            if case .terminated(0) = event { firstStopped.fulfill() }
        }
        first.start()
        wait(for: [firstStarted], timeout: 5)
        let port = try XCTUnwrap(awaitBoundPort(of: first))

        let client = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let tunneled = expectation(description: "session established")
        client.stateUpdateHandler = { state in
            guard case .ready = state else { return }
            client.send(content: Data("CONNECT 127.0.0.1:\(echoPort) HTTP/1.1\r\n\r\n".utf8),
                        completion: .idempotent)
            client.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, _ in
                XCTAssertTrue(String(decoding: data ?? Data(), as: UTF8.self).hasPrefix("HTTP/1.1 200"))
                tunneled.fulfill()
            }
        }
        client.start(queue: .global())
        wait(for: [tunneled], timeout: 10)

        // Stop with the session still open (its socket lands in TIME_WAIT). The terminal event
        // means the LISTENING socket is really closed — that is the moment `ProcessManager`
        // considers the daemon gone and a restart may bind again; the session's TIME_WAIT
        // remnant is exactly what survives past it.
        first.stop()
        wait(for: [firstStopped], timeout: 5)
        client.cancel()

        let secondStarted = expectation(description: "second started")
        let rebindFailed = expectation(description: "no bind failure")
        rebindFailed.isInverted = true
        let second = BuiltInProxyListener(port: port, auth: nil) { event in
            if case .started = event { secondStarted.fulfill() }
            if case .terminated(1) = event { rebindFailed.fulfill() }
        }
        second.start()
        defer { second.stop() }
        wait(for: [secondStarted], timeout: 5)
        XCTAssertEqual(awaitBoundPort(of: second), port, "the same port must be usable immediately")
        wait(for: [rebindFailed], timeout: 1)   // inverted: a terminated(1) within 1s fails the test
    }

    func testOccupiedPortEmitsTerminated1() throws {
        let (blocker, blockedPort) = try startEchoServer()
        defer { blocker.cancel() }
        let sink = EventSink()
        let terminated = expectation(description: "terminated(1)")
        let proxy = BuiltInProxyListener(port: blockedPort, auth: nil) { event in
            sink.append(event)
            if case .terminated(1) = event { terminated.fulfill() }
        }
        proxy.start()
        wait(for: [terminated], timeout: 10)
        // The invariant held: .started came first, and a .line explains the failure.
        if case .started = sink.snapshot.first {} else { XCTFail("first event must be .started") }
        XCTAssertTrue(sink.snapshot.contains { if case .line = $0 { return true }; return false })
    }

    /// `boundPort` is set on the listener's queue around the `.started` emit — poll briefly
    /// rather than assuming the write is visible the instant the expectation fulfils.
    private func awaitBoundPort(of proxy: BuiltInProxyListener) -> UInt16? {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let port = proxy.boundPort { return port }
            usleep(20_000)
        }
        return nil
    }
}
