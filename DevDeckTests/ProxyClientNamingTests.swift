import XCTest
@testable import DevDeck

/// Reverse naming of a peer. The pure shortening is covered exhaustively; the resolver itself is
/// exercised only where the answer is deterministic on any Mac (`/etc/hosts`) or needs no resolver
/// at all (malformed input), so the suite never waits on DNS.
final class ProxyClientNamingTests: XCTestCase {

    func testTrailingDotIsTrimmed() {
        XCTAssertEqual(shortHostName("macbook-vasya.local."), "macbook-vasya")
    }

    func testLocalSuffixIsTrimmed() {
        XCTAssertEqual(shortHostName("macbook-vasya.local"), "macbook-vasya")
    }

    func testOtherNamesSurviveIntact() {
        XCTAssertEqual(shortHostName("build-01.office.example.com"), "build-01.office.example.com")
        XCTAssertEqual(shortHostName("localhost"), "localhost")
    }

    func testMalformedAddressResolvesToNothing() {
        XCTAssertNil(reverseLookup("not-an-ip"))
        XCTAssertNil(reverseLookup(""))
    }

    func testLoopbackResolvesThroughTheHostsFile() {
        XCTAssertEqual(reverseLookup("127.0.0.1"), "localhost")
    }

    func testLiveNamingRunsOffTheCallersThread() async {
        let name = await ReverseDNSClientNaming().hostname(for: "127.0.0.1")
        XCTAssertEqual(name, "localhost")
    }
}
