import XCTest
@testable import DevDeck

final class SystemMemoryTests: XCTestCase {

    func testFormat() {
        // RAM is measured in binary GiB (how Apple labels "16 GB" = 16 GiB, and how htop shows it).
        XCTAssertEqual(
            SystemMemory.format(usedBytes: 12 * 1_073_741_824, totalBytes: 16 * 1_073_741_824),
            "12.0 / 16 GB · 75%"
        )
        XCTAssertEqual(
            SystemMemory.format(usedBytes: 8 * 1_073_741_824, totalBytes: 16 * 1_073_741_824),
            "8.0 / 16 GB · 50%"
        )
    }

    func testFormatGiB() {
        XCTAssertEqual(SystemMemory.formatGiB(1_825_361_100), "1.7 GB")   // ~1.7 GiB
        XCTAssertEqual(SystemMemory.formatGiB(0), "0.0 GB")
    }

    func testFraction() {
        XCTAssertEqual(SystemMemory(usedBytes: 8_000_000_000, totalBytes: 16_000_000_000).fraction, 0.5, accuracy: 0.001)
        XCTAssertEqual(SystemMemory(usedBytes: 5, totalBytes: 0).fraction, 0, "division by zero must not crash")
    }

    // MARK: - what counts as used

    func testUsedIsAppMemoryPlusWiredPlusCompressed() {
        // Real counters off a 48 GiB Mac with 16 KiB pages, captured while htop and Activity Monitor
        // both read 40/48 and this cell read 35/48: the 5.9 GiB gap was anonymous pages that had
        // gone inactive — droppable for free by nobody, only compressible or swappable.
        let used = SystemMemory.used(internalPages: 1_166_408, purgeablePages: 7_161,
                                          wiredPages: 266_644, compressorPages: 1_256_913,
                                          pageSize: 16_384)
        XCTAssertEqual(used, 2_682_804 * 16_384)
        XCTAssertEqual(SystemMemory.format(usedBytes: used, totalBytes: 51_539_607_552),
                       "40.9 / 48 GB · 85%")
    }

    func testPurgeablePagesAreNotUsed() {
        // The system can throw them away under pressure, so Activity Monitor leaves them out too.
        XCTAssertEqual(SystemMemory.used(internalPages: 100, purgeablePages: 40,
                                              wiredPages: 0, compressorPages: 0, pageSize: 4_096),
                       60 * 4_096)
    }

    func testMorePurgeableThanInternalDoesNotWrapAround() {
        // Two counters sampled a moment apart can disagree; on UInt64 the subtraction would wrap
        // to 16 exabytes and the bar would peg at 100%.
        XCTAssertEqual(SystemMemory.used(internalPages: 10, purgeablePages: 25,
                                              wiredPages: 5, compressorPages: 0, pageSize: 4_096),
                       5 * 4_096)
    }
}
