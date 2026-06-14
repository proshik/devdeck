import XCTest
@testable import DevDeck

/// Ring buffer — a pure value type, tested in isolation (no async).
final class RingBufferTests: XCTestCase {

    func testDropsOldestKeepsOrder() {
        var buffer = RingBuffer<Int>(capacity: 3)
        for i in 1...5 { buffer.append(i) }
        XCTAssertEqual(buffer.elements, [3, 4, 5])
        XCTAssertEqual(buffer.count, 3)
    }

    func testUnderCapacityKeepsInsertionOrder() {
        var buffer = RingBuffer<Int>(capacity: 5)
        buffer.append(10)
        buffer.append(20)
        XCTAssertEqual(buffer.elements, [10, 20])
        XCTAssertEqual(buffer.count, 2)
    }

    func testExactCapacityThenOverflow() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1); buffer.append(2); buffer.append(3)
        XCTAssertEqual(buffer.elements, [1, 2, 3])
        buffer.append(4)
        XCTAssertEqual(buffer.elements, [2, 3, 4])
        XCTAssertEqual(buffer.count, 3)
    }

    func testClearResets() {
        var buffer = RingBuffer<Int>(capacity: 3)
        buffer.append(1); buffer.append(2)
        buffer.clear()
        XCTAssertEqual(buffer.elements, [])
        XCTAssertEqual(buffer.count, 0)
    }
}
