import XCTest
@testable import DevDeck

final class HostMetricsTests: XCTestCase {
    func testPressureLevelFromRaw() {
        XCTAssertEqual(MemoryPressureLevel(raw: 1), .normal)
        XCTAssertEqual(MemoryPressureLevel(raw: 2), .warning)
        XCTAssertEqual(MemoryPressureLevel(raw: 4), .critical)
        XCTAssertEqual(MemoryPressureLevel(raw: 0), .normal)   // unknown → normal
    }

    func testSwapRateIsDeltaOverTime() {
        let rate = swapRatePagesPerSec(prevIn: 1000, prevOut: 500,
                                       curIn: 1000 + 8192, curOut: 500,
                                       dtSeconds: 2)
        XCTAssertEqual(rate.inPerSec, 4096, accuracy: 0.5)
        XCTAssertEqual(rate.outPerSec, 0, accuracy: 0.5)
        let reset = swapRatePagesPerSec(prevIn: 10_000, prevOut: 0, curIn: 5, curOut: 0, dtSeconds: 1)
        XCTAssertEqual(reset.inPerSec, 0, "counter reset must not produce a negative rate")
    }

    func testCompressorFractionAndFormat() {
        let s = HostMetricsSample(pressure: .warning, swapInsPages: 0, swapOutsPages: 0,
                                  compressorPages: 262_144, totalBytes: 16 * 1_073_741_824,
                                  buildFootprintBytes: 0)
        XCTAssertEqual(s.compressorBytes(pageSize: 16384), 4 * 1_073_741_824)
        XCTAssertEqual(HostMetricsSample.formatRate(pagesPerSec: 4096, pageSize: 16384), "64.0 MB/s")
        XCTAssertEqual(HostMetricsSample.formatRate(pagesPerSec: 0, pageSize: 16384), "0 MB/s")
    }
}
