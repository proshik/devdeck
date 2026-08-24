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

    func testParseColimaCpus() {
        let json = #"{"name":"default","status":"Running","memory":10737418240,"cpus":6}"#
        XCTAssertEqual(VMMemoryInfo.parseColimaCpus(json), 6)
        XCTAssertNil(VMMemoryInfo.parseColimaCpus("not json"))
    }
}

final class VMMemoryMeminfoTests: XCTestCase {
    // Real `/proc/meminfo` head from the colima guest (only the first lines matter).
    private let sample = """
    MemTotal:       30737808 kB
    MemFree:         5597800 kB
    MemAvailable:   19553980 kB
    Buffers:          928384 kB
    Cached:         12693564 kB
    """

    func testParseMeminfoUsesTotalMinusAvailable() throws {
        let info = try XCTUnwrap(VMMemoryInfo.parseMeminfo(sample))
        XCTAssertEqual(info.limitBytes, 30_737_808 * 1024)
        XCTAssertEqual(info.usedBytes, (30_737_808 - 19_553_980) * 1024)
    }

    func testParseMeminfoRejectsGarbage() {
        XCTAssertNil(VMMemoryInfo.parseMeminfo(""))
        XCTAssertNil(VMMemoryInfo.parseMeminfo("cat: /proc/meminfo: No such file or directory"))
        // Without MemAvailable (pre-3.14 kernels) we'd rather show nothing than a wrong number.
        XCTAssertNil(VMMemoryInfo.parseMeminfo("MemTotal:       30737808 kB\nMemFree:         5597800 kB"))
        // Zero total must not produce a division-by-zero cell.
        XCTAssertNil(VMMemoryInfo.parseMeminfo("MemTotal:       0 kB\nMemAvailable:   0 kB"))
        // Available > total is nonsense — treat as unparsable rather than clamp silently.
        XCTAssertNil(VMMemoryInfo.parseMeminfo("MemTotal:       10 kB\nMemAvailable:   20 kB"))
    }
}
