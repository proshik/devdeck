import XCTest
@testable import DevDeck

/// The gost log parser. Every sample below was captured verbatim from `gost 3.2.6` driving a real
/// listener, so a format change in a future gost breaks these tests rather than the UI silently.
final class ProxyClientLogTests: XCTestCase {

    private let opened = """
        {"client":"192.168.31.42:55904","handler":"http","kind":"handler","level":"info",\
        "listener":"tcp","local":"192.168.31.5:9999","msg":"192.168.31.42:55904 <> 192.168.31.5:9999",\
        "network":"","remote":"192.168.31.42:55904","service":"devdeck-proxy","sid":"d9q51fl1837ipckfutrg",\
        "time":"2026-08-06T12:15:42.246+03:00"}
        """

    private let closed = """
        {"client":"192.168.31.42:55904","duration":435225125,"handler":"http","inputBytes":706,\
        "kind":"handler","level":"info","listener":"tcp","local":"192.168.31.5:9999",\
        "msg":"192.168.31.42:55904 >< 192.168.31.5:9999","network":"","outputBytes":3105,\
        "remote":"192.168.31.42:55904","service":"devdeck-proxy","sid":"d9q51fl1837ipckfutrg",\
        "time":"2026-08-06T12:15:42.681+03:00"}
        """

    /// A dial to ONE destination inside a live session — must not be counted as a second session.
    private let dialed = """
        {"client":"192.168.31.42:55904","clientID":"","dst":"104.26.13.205:443","handler":"http",\
        "host":"api.ipify.org:443","kind":"handler","level":"info","listener":"tcp",\
        "local":"192.168.31.5:9999","msg":"192.168.31.42:55904 <-> api.ipify.org:443","network":"tcp",\
        "remote":"192.168.31.42:55904","service":"devdeck-proxy","sid":"d9q51fl1837ipckfutrg",\
        "time":"2026-08-06T12:15:42.384+03:00"}
        """

    private let dialClosed = """
        {"client":"192.168.31.42:55904","clientID":"","dst":"104.26.13.205:443","duration":297735250,\
        "handler":"http","host":"api.ipify.org:443","kind":"handler","level":"info","listener":"tcp",\
        "local":"192.168.31.5:9999","msg":"192.168.31.42:55904 >-< api.ipify.org:443","network":"tcp",\
        "remote":"192.168.31.42:55904","service":"devdeck-proxy","sid":"d9q51fl1837ipckfutrg",\
        "time":"2026-08-06T12:15:42.681+03:00"}
        """

    private let startup = """
        {"handler":"auto","kind":"service","level":"info","listener":"tcp",\
        "msg":"listening on [::]:9999/tcp","service":"devdeck-proxy",\
        "time":"2026-08-06T12:15:40.248+03:00"}
        """

    func testSessionOpenIsRecognized() {
        XCTAssertEqual(parseGostLogLine(opened),
                       .sessionOpened(client: "192.168.31.42:55904", sid: "d9q51fl1837ipckfutrg"))
    }

    func testSessionCloseIsRecognized() {
        XCTAssertEqual(parseGostLogLine(closed), .sessionClosed(sid: "d9q51fl1837ipckfutrg"))
    }

    func testDestinationDialsAreIgnored() {
        XCTAssertNil(parseGostLogLine(dialed), "'<->' is a dial inside a session, not a new session")
        XCTAssertNil(parseGostLogLine(dialClosed), "'>-<' closes a destination, not the session")
    }

    func testServiceLinesAndGarbageAreIgnored() {
        XCTAssertNil(parseGostLogLine(startup))
        XCTAssertNil(parseGostLogLine(""))
        XCTAssertNil(parseGostLogLine("gost: command not found"))
        XCTAssertNil(parseGostLogLine("{\"client\":\"1.2.3.4:5\",\"msg\":\"1.2.3.4:5 <> x\"}"),
                     "no sid → not a session event")
    }

    func testClientIPDropsTheEphemeralPort() {
        XCTAssertEqual(proxyClientIP("192.168.31.42:55904"), "192.168.31.42")
    }

    func testClientIPUnwrapsIPv6() {
        XCTAssertEqual(proxyClientIP("[fe80::1%en0]:55904"), "fe80::1%en0")
    }

    func testClientIPRejectsGarbage() {
        XCTAssertNil(proxyClientIP("192.168.31.42"), "no port → not a gost client string")
        XCTAssertNil(proxyClientIP(":55904"))
    }
}
