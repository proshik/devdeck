import XCTest
@testable import DevDeck

final class BrightnessDDCWriteTests: XCTestCase {
    func testRepeatedIdenticalSetAppliesMonitorRequiringHandshake() throws {
        var packets: [[UInt8]] = [], waits: [UInt32] = []
        var actual: UInt16 = 99
        try BrightnessDDCWriteTransaction.write(94, send: { packet in
            packets.append(packet)
            if packets.count == 2 && packets[0] == packet { actual = 94 }
            return 0
        }, wait: { waits.append($0) })
        XCTAssertEqual(actual, 94)
        XCTAssertEqual(packets, [BrightnessDDC.write(94), BrightnessDDC.write(94)])
        XCTAssertEqual(waits, [10_000, 50_000])
    }
    func testEitherTransferFailureThrowsWithoutRetry() {
        for statuses: [Int32] in [[-1], [0, -1]] {
            var calls = 0
            XCTAssertThrowsError(try BrightnessDDCWriteTransaction.write(94, send: { _ in
                defer { calls += 1 }; return statuses[calls]
            }, wait: { _ in }))
            XCTAssertEqual(calls, statuses.count)
        }
    }
    func testCancellationBeforeFirstDuringGapAndDuringSettlingStopsLaterHardware() {
        for cancelAt in [0, 10_000, 50_000] {
            var cancelled = cancelAt == 0, sends = 0, followingRead = false
            do {
                try BrightnessDDCWriteTransaction.write(94, send: { _ in sends += 1; return 0 }, wait: { delay in
                    if delay == cancelAt { cancelled = true }
                }, cancelled: { cancelled })
                followingRead = true
                XCTFail("cancelled transaction must throw")
            } catch is CancellationError {} catch { XCTFail("unexpected error \(error)") }
            XCTAssertEqual(sends, cancelAt == 0 ? 0 : (cancelAt == 10_000 ? 1 : 2))
            XCTAssertFalse(followingRead)
        }
    }
    func testConfirmationAllowsOnlyOneHardwareUnitAndRejectsStaleValue() throws {
        for actual: UInt16 in [93, 94, 95] {
            XCTAssertEqual(try BrightnessDDCWriteTransaction.confirm(target: 94, maximum: 100, reading: (actual, 100)), Double(actual) / 100)
        }
        for actual: UInt16 in [92, 96, 99] {
            XCTAssertThrowsError(try BrightnessDDCWriteTransaction.confirm(target: 94, maximum: 100, reading: (actual, 100))) { error in
                guard case BrightnessFailure.unconfirmed(let observed) = error else { return XCTFail("expected observed mismatch") }
                XCTAssertEqual(observed, Double(actual) / 100)
            }
        }
    }
    func testInvalidOrChangedMaximumCannotConfirm() {
        for (target, maximum, current, readMaximum): (UInt16, UInt16, UInt16, UInt16) in [(0,0,0,0), (101,100,99,100), (94,100,101,100), (94,100,94,200)] {
            XCTAssertThrowsError(try BrightnessDDCWriteTransaction.confirm(target: target, maximum: maximum, reading: (current, readMaximum)))
        }
        XCTAssertThrowsError(try BrightnessDDCWriteTransaction.confirm(target: 9, maximum: 10, reading: (10, 10)))
    }
}
