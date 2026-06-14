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
}
