import XCTest
@testable import DevDeck

final class VMMemoryTests: XCTestCase {
    func testFractionAndHeadroom() {
        let i = VMMemoryInfo(usedBytes: 7 * 1_073_741_824, limitBytes: 10 * 1_073_741_824)
        XCTAssertEqual(i.fraction, 0.7, accuracy: 0.001)
        XCTAssertEqual(i.headroomFraction, 0.3, accuracy: 0.001)
    }

    func testFormatBinaryGiB() {
        let i = VMMemoryInfo(usedBytes: 6_871_947_674, limitBytes: 10 * 1_073_741_824) // ~6.4
        XCTAssertEqual(i.format(), "6.4 / 10 GiB · 64%")
    }

    func testParseColimaLimit() {
        let json = #"{"name":"default","status":"Running","memory":10737418240,"cpus":6}"#
        XCTAssertEqual(VMMemoryInfo.parseColimaLimitBytes(json), 10_737_418_240)
        XCTAssertNil(VMMemoryInfo.parseColimaLimitBytes("not json"))
    }
}
