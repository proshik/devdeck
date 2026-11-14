import XCTest
@testable import DevDeck

final class BrightnessDDCTransactionTests: XCTestCase {
    private let get: [UInt8] = [0x82, 0x01, 0x10, 0xfd]
    func testMonitorRequiringRepeatedGetReturnsRealValueWithBoundedSequence() {
        let transport = Transport()
        let value = BrightnessDDCReadTransaction.read(send: transport.send, receive: transport.receive, wait: transport.wait)
        XCTAssertEqual(value?.current, 99); XCTAssertEqual(value?.maximum, 100)
        XCTAssertEqual(transport.events, [.send(get), .wait(10_000), .send(get), .wait(50_000), .read])
    }
    func testFailedFirstOrSecondGetDoesNotReadAndRetriesAreBounded() {
        for statuses: [Int32] in [[-1, -1], [0, -1, 0, -1]] {
            let transport = Transport(); transport.statuses = statuses
            XCTAssertNil(BrightnessDDCReadTransaction.read(send: transport.send, receive: transport.receive, wait: transport.wait))
            XCTAssertEqual(transport.events.filter { $0 == .read }.count, 0)
            XCTAssertEqual(transport.sent.count, statuses.count)
            XCTAssertTrue(transport.sent.allSatisfy { $0 == get })
        }
    }
    func testReadFailureCannotReturnOtherwiseValidPacket() {
        let transport = Transport(); transport.readStatus = -1
        XCTAssertNil(BrightnessDDCReadTransaction.read(send: transport.send, receive: transport.receive, wait: transport.wait))
        XCTAssertEqual(transport.sent.count, 4)
        XCTAssertEqual(transport.events.filter { $0 == .read }.count, 2)
    }
    func testNullCorruptWrongControlStatusAndInvalidBoundsStayUnavailable() {
        var corrupt = packet(); corrupt[10] ^= 1
        for bytes in [[0x6e, 0x80, 0xbe, 0, 0, 0, 0, 0, 0, 0, 0], corrupt,
                      packet(status: 1), packet(control: 0x12), packet(maximum: 0, current: 0),
                      packet(maximum: 100, current: 101)] {
            let transport = Transport(); transport.reply = bytes
            XCTAssertNil(BrightnessDDCReadTransaction.read(send: transport.send, receive: transport.receive, wait: transport.wait))
            XCTAssertEqual(transport.sent.count, 4, "invalid replies must not bypass bounded retries")
        }
    }
    func testAlreadyCancelledReadSendsNothing() {
        let transport = Transport()
        XCTAssertNil(BrightnessDDCReadTransaction.read(send: transport.send, receive: transport.receive,
                                                      wait: transport.wait, cancelled: { true }))
        XCTAssertTrue(transport.events.isEmpty)
    }
    func testTaskCancellationDuringExtraWaitStopsTransfersBeforeFollowingSet() async {
        let transport = Transport()
        let task = Task {
            _ = BrightnessDDCReadTransaction.read(send: transport.send, receive: transport.receive, wait: { delay in
                transport.wait(delay)
                if delay == 10_000 { withUnsafeCurrentTask { $0?.cancel() } }
            })
            // The production provider also checks cancellation after its pre-SET read.
            try Task.checkCancellation()
            transport.followingSetCalls += 1
        }
        do { try await task.value; XCTFail("cancelled read must not reach SET") } catch is CancellationError {} catch { XCTFail("unexpected error") }
        XCTAssertEqual(transport.sent, [get]); XCTAssertEqual(transport.followingSetCalls, 0)
        XCTAssertFalse(transport.events.contains(.read))
    }
    private func packet(status: UInt8 = 0, control: UInt8 = 0x10, maximum: UInt16 = 100, current: UInt16 = 99) -> [UInt8] {
        var bytes: [UInt8] = [0x6e, 0x88, 0x02, status, control, 0, UInt8(maximum >> 8), UInt8(maximum & 255), UInt8(current >> 8), UInt8(current & 255)]
        bytes.append(bytes.reduce(0x50, ^)); return bytes
    }
    private enum Event: Equatable { case send([UInt8]), wait(UInt32), read }
    /// Models the observed monitor: a single GET produces a null response, two produce VCP.
    private final class Transport: @unchecked Sendable {
        var events: [Event] = [], sent: [[UInt8]] = [], statuses: [Int32] = []
        var readStatus: Int32 = 0, followingSetCalls = 0
        var reply: [UInt8] = [0x6e, 0x88, 0x02, 0, 0x10, 0, 0, 100, 0, 99, 0xa3]
        private var sinceRead = 0
        func send(_ bytes: [UInt8]) -> Int32 {
            events.append(.send(bytes)); sent.append(bytes); sinceRead += 1
            return statuses.isEmpty ? 0 : statuses.removeFirst()
        }
        func wait(_ delay: UInt32) { events.append(.wait(delay)) }
        func receive() -> (Int32, [UInt8]) {
            events.append(.read); defer { sinceRead = 0 }
            return (readStatus, sinceRead >= 2 ? reply : [0x6e, 0x80, 0xbe, 0, 0, 0, 0, 0, 0, 0, 0])
        }
    }
}
