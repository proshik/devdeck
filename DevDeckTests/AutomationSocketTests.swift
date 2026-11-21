import XCTest
import Darwin
@testable import DevDeck

/// Loopback tests of the CLI transport: a real Unix socket in a throwaway directory, a real
/// client, a stub handler. What a request *does* is covered by `AutomationRequestRouterTests`.
final class AutomationSocketTests: XCTestCase {

    private var directory: URL!
    private var socketURL: URL!
    private var servers: [AutomationSocketServer] = []

    /// A short path: `sun_path` holds 104 bytes and the test host's temp directory is long.
    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: "/tmp/ddsock-\(UUID().uuidString.prefix(8))", isDirectory: true)
        socketURL = directory.appendingPathComponent("a.sock")
    }

    override func tearDownWithError() throws {
        servers.forEach { $0.stop() }
        try? FileManager.default.removeItem(at: directory)
    }

    private final class Calls: @unchecked Sendable {
        private let lock = NSLock()
        private var requests: [AutomationRequest] = []
        func record(_ request: AutomationRequest) { lock.lock(); requests.append(request); lock.unlock() }
        var all: [AutomationRequest] { lock.lock(); defer { lock.unlock() }; return requests }
    }

    @discardableResult
    private func startServer(expectedUID: uid_t = getuid(), calls: Calls = Calls(), delay: Duration = .zero,
                             file: StaticString = #filePath, line: UInt = #line) throws -> AutomationSocketServer {
        let server = AutomationSocketServer(socketURL: socketURL, expectedUID: expectedUID) { request in
            calls.record(request)
            if delay > .zero { try? await Task.sleep(for: delay) }
            return AutomationResponse(exitCode: 0, stdout: "ok \(request.target ?? "-")", stderr: "")
        }
        try server.start()
        servers.append(server)
        return server
    }

    private func send(_ request: AutomationRequest = AutomationRequest(operation: .status, kind: .command, target: "echo"),
                      expectedUID: uid_t = getuid(), timeout: TimeInterval = 5)
        -> Result<AutomationResponse, AutomationSocketClient.Failure> {
        AutomationSocketClient.send(request, socketURL: socketURL, expectedUID: expectedUID, receiveTimeout: timeout)
    }

    private func mode(_ url: URL) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int)
    }

    func testRoundTripAndOwnerOnlyPermissions() throws {
        let calls = Calls()
        try startServer(calls: calls)

        XCTAssertEqual(try send().get(), AutomationResponse(exitCode: 0, stdout: "ok echo", stderr: ""))
        XCTAssertEqual(calls.all.map(\.target), ["echo"])
        XCTAssertEqual(mode(socketURL), 0o600)
        XCTAssertEqual(mode(directory), 0o700)
    }

    func testNoSocketMeansAppNotRunning() {
        XCTAssertEqual(send().failure, .notRunning)
    }

    func testStopRemovesTheSocket() throws {
        let server = try startServer()
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketURL.path))
        XCTAssertEqual(send().failure, .notRunning)
    }

    func testStaleSocketIsNotRunningAndIsReplaced() throws {
        try makeStaleSocket()
        XCTAssertEqual(send().failure, .notRunning, "a socket nobody listens on is a dead app")

        try startServer()
        XCTAssertEqual(try send().get().stdout, "ok echo")
    }

    func testLiveSocketOfAnotherInstanceIsNotTaken() throws {
        let calls = Calls()
        try startServer(calls: calls)
        let second = AutomationSocketServer(socketURL: socketURL) { _ in
            AutomationResponse(exitCode: 9, stdout: "second", stderr: "")
        }
        XCTAssertThrowsError(try second.start()) { error in
            XCTAssertEqual(error as? AutomationSocketError, .alreadyServing)
        }
        second.stop()
        XCTAssertEqual(try send().get().stdout, "ok echo", "the first instance keeps serving")
    }

    func testNonSocketFileIsLeftAlone() throws {
        try PrivateFile.makeDirectory(at: directory)
        try Data("keep me".utf8).write(to: socketURL)
        let server = AutomationSocketServer(socketURL: socketURL) { _ in AutomationResponse(exitCode: 0, stdout: "", stderr: "") }
        XCTAssertThrowsError(try server.start())
        XCTAssertEqual(try String(contentsOf: socketURL, encoding: .utf8), "keep me")
    }

    func testTooLongPathIsRejected() {
        let long = URL(fileURLWithPath: "/tmp/" + String(repeating: "d", count: 120) + "/a.sock")
        let server = AutomationSocketServer(socketURL: long) { _ in AutomationResponse(exitCode: 0, stdout: "", stderr: "") }
        XCTAssertThrowsError(try server.start()) { error in
            XCTAssertEqual(error as? AutomationSocketError, .pathTooLong)
        }
        if case .communication = AutomationSocketClient.send(AutomationRequest(operation: .list), socketURL: long,
                                                             receiveTimeout: 1).failure {} else {
            XCTFail("a client cannot reach a path that does not fit sun_path")
        }
    }

    func testGarbageRequestIsAnsweredWithoutCallingTheHandler() throws {
        let calls = Calls()
        try startServer(calls: calls)

        let reply = try rawExchange("this is not json\n")
        let response = try AutomationWire.decodeResponse(reply)

        XCTAssertEqual(response.exitCode, AutomationExitCode.communication)
        XCTAssertFalse(response.stderr.isEmpty)
        XCTAssertTrue(calls.all.isEmpty)
    }

    func testForeignVersionIsAnsweredWithoutCallingTheHandler() throws {
        let calls = Calls()
        try startServer(calls: calls)
        var request = AutomationRequest(operation: .list)
        request.version = 2

        let response = try AutomationWire.decodeResponse(rawExchange(String(decoding: AutomationWire.encode(request), as: UTF8.self)))

        XCTAssertEqual(response.exitCode, AutomationExitCode.communication)
        XCTAssertTrue(calls.all.isEmpty)
    }

    func testOversizedRequestIsRejected() throws {
        let calls = Calls()
        try startServer(calls: calls)
        let reply = try rawExchange(String(repeating: "x", count: AutomationWire.maxRequestBytes + 10) + "\n")
        XCTAssertEqual(try AutomationWire.decodeResponse(reply).exitCode, AutomationExitCode.communication)
        XCTAssertTrue(calls.all.isEmpty)
    }

    func testPeerOfAnotherUserIsDropped() throws {
        let calls = Calls()
        try startServer(expectedUID: getuid() &+ 1, calls: calls)

        guard case .communication = send().failure else { return XCTFail("a foreign peer gets no answer") }
        XCTAssertTrue(calls.all.isEmpty)
    }

    func testClientRefusesASocketOfAnotherUser() throws {
        let calls = Calls()
        try startServer(calls: calls)
        guard case .communication = send(expectedUID: getuid() &+ 1).failure else {
            return XCTFail("the client must check who it is talking to")
        }
        XCTAssertTrue(calls.all.isEmpty, "no request is sent to a foreign server")
    }

    func testClientGivesUpAfterItsTimeout() throws {
        try startServer(delay: .seconds(2))
        let started = Date()
        guard case .communication = send(timeout: 0.3).failure else { return XCTFail("expected a timeout") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }

    func testConcurrentClientsAreServed() throws {
        try startServer(delay: .milliseconds(100))
        let results = Results()
        DispatchQueue.concurrentPerform(iterations: 6) { index in
            let result = AutomationSocketClient.send(AutomationRequest(operation: .status, kind: .command, target: "c\(index)"),
                                                     socketURL: socketURL, receiveTimeout: 5)
            results.add((try? result.get().stdout) ?? "fail")
        }
        XCTAssertEqual(Set(results.all), Set((0..<6).map { "ok c\($0)" }))
    }

    // MARK: helpers

    private final class Results: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [String] = []
        func add(_ value: String) { lock.lock(); values.append(value); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return values }
    }

    /// A socket file left behind by a crashed app: bound, never listening, closed.
    private func makeStaleSocket() throws {
        try PrivateFile.makeDirectory(at: directory)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try XCTUnwrap(AutomationSocketAddress(path: socketURL.path))
        let bound = address.withSockaddr { Darwin.bind(fd, $0, $1) }
        close(fd)
        XCTAssertEqual(bound, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketURL.path))
    }

    /// Write raw bytes and read the whole reply — what a foreign or broken client would do.
    private func rawExchange(_ text: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = try XCTUnwrap(AutomationSocketAddress(path: socketURL.path))
        XCTAssertEqual(address.withSockaddr { Darwin.connect(fd, $0, $1) }, 0)
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let bytes = Array(text.utf8)
        _ = bytes.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        var reply = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = Darwin.read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            reply.append(contentsOf: buffer[0..<n])
        }
        return reply
    }
}

private extension Result {
    var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
