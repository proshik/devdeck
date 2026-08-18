import Foundation
import Network

/// Minimal SOCKS5 server for loopback tests: performs the no-auth handshake, RECORDS each
/// request's address type/address/port, replies success, then serves the "tunnel" itself by
/// echoing every byte back — no onward dial, so a test controls both ends.
///
/// The recorded address is the point: the bridge must forward HOSTNAMES to SOCKS
/// (ATYP=0x03/domain), never resolve them locally — resolution belongs to the VDS.
final class FakeSOCKSServer: @unchecked Sendable {

    struct Request: Equatable {
        let atyp: UInt8          // 0x01 IPv4, 0x03 domain, 0x04 IPv6
        let address: String
        let port: Int
    }

    /// Thread-safe request log, shared with the connection handlers by reference so the
    /// listener's callbacks never need `self` during init.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [Request] = []
        func append(_ request: Request) { lock.lock(); requests.append(request); lock.unlock() }
        var snapshot: [Request] { lock.lock(); defer { lock.unlock() }; return requests }
    }

    private let recorder: Recorder
    private let listener: NWListener
    let port: UInt16

    var requests: [Request] { recorder.snapshot }

    /// Blocks (briefly) until the ephemeral port is bound.
    static func start() throws -> FakeSOCKSServer {
        try FakeSOCKSServer()
    }

    private init() throws {
        let recorder = Recorder()
        self.recorder = recorder
        let listener = try NWListener(using: .tcp)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            if case .ready = state { ready.signal() }
        }
        listener.newConnectionHandler = { connection in
            Self.serve(connection, into: recorder)
        }
        listener.start(queue: DispatchQueue(label: "fake-socks"))
        guard ready.wait(timeout: .now() + 5) == .success, let bound = listener.port?.rawValue else {
            listener.cancel()
            throw NSError(domain: "FakeSOCKSServer", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "listener never became ready"])
        }
        port = bound
    }

    func stop() { listener.cancel() }

    // MARK: - One connection

    private enum Phase { case greeting, request, echo }

    private static func serve(_ connection: NWConnection, into recorder: Recorder) {
        let queue = DispatchQueue(label: "fake-socks-conn")
        var buffer = Data()
        var phase = Phase.greeting
        connection.start(queue: queue)

        func pump() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, done, error in
                if let data { buffer.append(data) }
                advance(connection, &buffer, &phase, recorder)
                if done || error != nil { connection.cancel() } else { pump() }
            }
        }
        pump()
    }

    /// Consume as much of the buffer as the current phase allows; echo everything once tunneled.
    private static func advance(_ connection: NWConnection, _ buffer: inout Data,
                                _ phase: inout Phase, _ recorder: Recorder) {
        if case .greeting = phase {
            guard buffer.count >= 2 else { return }
            let methods = Int(buffer[buffer.startIndex + 1])
            guard buffer.count >= 2 + methods else { return }
            buffer.removeFirst(2 + methods)
            connection.send(content: Data([0x05, 0x00]), completion: .idempotent)   // no auth
            phase = .request
        }
        if case .request = phase {
            guard buffer.count >= 5 else { return }
            let bytes = [UInt8](buffer)
            let atyp = bytes[3]
            let addrLen: Int
            switch atyp {
            case 0x01: addrLen = 4
            case 0x03: addrLen = 1 + Int(bytes[4])
            case 0x04: addrLen = 16
            default: connection.cancel(); return
            }
            guard bytes.count >= 4 + addrLen + 2 else { return }
            let address: String
            switch atyp {
            case 0x01: address = bytes[4..<8].map(String.init).joined(separator: ".")
            case 0x03: address = String(decoding: bytes[5..<(5 + Int(bytes[4]))], as: UTF8.self)
            default: address = Data(bytes[4..<20]).map { String(format: "%02x", $0) }.joined()
            }
            let port = Int(bytes[4 + addrLen]) << 8 | Int(bytes[4 + addrLen + 1])
            recorder.append(Request(atyp: atyp, address: address, port: port))
            buffer.removeFirst(4 + addrLen + 2)
            connection.send(content: Data([0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]),
                            completion: .idempotent)                                 // success
            phase = .echo
        }
        if case .echo = phase, !buffer.isEmpty {
            connection.send(content: buffer, completion: .idempotent)
            buffer.removeAll()
        }
    }
}
