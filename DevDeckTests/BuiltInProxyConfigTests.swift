import XCTest
@testable import DevDeck

/// The writer (`gostConfigJSON`) and the reader are asserted against each other: both engines
/// start from the same generated file, so a drift between them would break only the built-in one.
final class BuiltInProxyConfigTests: XCTestCase {

    func testRoundTripWithAuth() throws {
        let share = ProxyShare(port: 9876, authEnabled: true, username: "dev")
        let json = try XCTUnwrap(share.gostConfigJSON(password: "s3cr:et"))
        let parsed = try XCTUnwrap(parseBuiltInProxyConfig(Data(json.utf8)))
        XCTAssertEqual(parsed.port, 9876)
        XCTAssertEqual(parsed.auth, GostAuth(username: "dev", password: "s3cr:et"))
    }

    func testRoundTripOpenProxy() throws {
        let share = ProxyShare(port: 9999, authEnabled: false)
        let json = try XCTUnwrap(share.gostConfigJSON(password: nil))
        let parsed = try XCTUnwrap(parseBuiltInProxyConfig(Data(json.utf8)))
        XCTAssertEqual(parsed.port, 9999)
        XCTAssertNil(parsed.auth)
    }

    func testMalformedInputsReturnNil() {
        XCTAssertNil(parseBuiltInProxyConfig(Data("not json".utf8)))
        XCTAssertNil(parseBuiltInProxyConfig(Data(#"{"services": []}"#.utf8)))
        XCTAssertNil(parseBuiltInProxyConfig(Data(
            #"{"services":[{"name":"x","addr":"nonsense","handler":{"type":"auto"},"listener":{"type":"tcp"}}]}"#
                .utf8)))
    }
}
