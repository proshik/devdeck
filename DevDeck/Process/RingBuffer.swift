import Foundation

/// Fixed-capacity ring buffer: `append` in O(1); when full, overwrites the OLDEST element.
/// Guards against memory leaks from lengthy/daemon output. Separate value type
/// (like `ConfigCodec`) — clean unit tests without async.
/// Intended for use from the main actor only (synchronization = actor isolation).
struct RingBuffer<Element> {
    private var storage: [Element?]
    private var head = 0           // index of the next write position
    private(set) var count = 0     // 0...capacity
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity > 0, "ring buffer capacity must be > 0")
        self.capacity = capacity
        self.storage = Array(repeating: nil, count: capacity)
    }

    mutating func append(_ element: Element) {
        storage[head] = element
        head = (head + 1) % capacity
        if count < capacity { count += 1 }
    }

    /// Elements from oldest to newest.
    var elements: [Element] {
        guard count > 0 else { return [] }
        // While the buffer is not full — oldest is at index 0; once full — at head.
        let start = count < capacity ? 0 : head
        return (0..<count).map { storage[(start + $0) % capacity]! }
    }

    mutating func clear() {
        storage = Array(repeating: nil, count: capacity)
        head = 0
        count = 0
    }
}
