import XCTest
@testable import DevDeck

/// The pure half of the built-in proxy engine: byte-in/byte-out, no sockets anywhere.
final class HTTPProxyParserTests: XCTestCase {

    private func head(_ s: String) -> HTTPRequestHead {
        parseHTTPRequestHead(Data(s.utf8))!
    }

    // MARK: - Head parsing

    func testParsesConnectHead() {
        let h = head("CONNECT api.ipify.org:443 HTTP/1.1\r\nHost: api.ipify.org:443\r\nUser-Agent: curl/8.6")
        XCTAssertEqual(h.method, "CONNECT")
        XCTAssertEqual(h.target, "api.ipify.org:443")
        XCTAssertEqual(h.version, "HTTP/1.1")
        XCTAssertEqual(h.firstValue(of: "user-agent"), "curl/8.6")
    }

    func testRejectsGarbage() {
        XCTAssertNil(parseHTTPRequestHead(Data("\u{16}\u{03}tls-client-hello".utf8)), "TLS bytes are not HTTP")
        XCTAssertNil(parseHTTPRequestHead(Data("ONLYONEWORD\r\n".utf8)))
        XCTAssertNil(parseHTTPRequestHead(Data()))
        XCTAssertNil(parseHTTPRequestHead(Data("GET / NOTHTTP\r\n".utf8)))
        XCTAssertNil(parseHTTPRequestHead(Data("GET / HTTP/1.1\r\nbroken header line".utf8)))
    }

    // MARK: - Classification

    func testClassifiesConnect() {
        XCTAssertEqual(classifyProxyRequest(head("CONNECT example.com:443 HTTP/1.1")),
                       .connect(host: "example.com", port: 443))
        XCTAssertEqual(classifyProxyRequest(head("CONNECT [::1]:8443 HTTP/1.1")),
                       .connect(host: "::1", port: 8443))
        XCTAssertEqual(classifyProxyRequest(head("CONNECT noport HTTP/1.1")), .bad)
    }

    func testClassifiesAbsoluteFormAndRewrites() throws {
        let kind = classifyProxyRequest(head(
            "GET http://example.com/a/b?q=1 HTTP/1.1\r\nHost: example.com\r\n"
                + "Proxy-Connection: keep-alive\r\nProxy-Authorization: Basic Zm9v\r\nAccept: */*"))
        guard case .absoluteForm(let host, let port, let rewritten) = kind else {
            return XCTFail("expected absoluteForm, got \(kind)")
        }
        XCTAssertEqual(host, "example.com")
        XCTAssertEqual(port, 80)
        let text = String(decoding: rewritten, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("GET /a/b?q=1 HTTP/1.1\r\n"), "request line must be origin-form")
        XCTAssertTrue(text.hasSuffix("\r\n\r\n"), "the rewritten head must be send-ready, terminator included")
        XCTAssertTrue(text.contains("Host: example.com\r\n"))
        XCTAssertTrue(text.contains("Accept: */*\r\n"))
        XCTAssertFalse(text.lowercased().contains("proxy-"), "hop-by-hop proxy headers must not reach the origin")
    }

    func testAbsoluteFormNonDefaultPortAndOriginFormRejected() {
        XCTAssertEqual(classifyProxyRequest(head("GET http://example.com:8080/x HTTP/1.1\r\nHost: h")).hostPort,
                       "example.com:8080")
        XCTAssertEqual(classifyProxyRequest(head("GET /just/a/path HTTP/1.1\r\nHost: h")), .bad,
                       "origin-form has no destination — this proxy is not an origin server")
        XCTAssertEqual(classifyProxyRequest(head("GET https://example.com/ HTTP/1.1\r\nHost: h")), .bad,
                       "https:// absolute-form through a plain proxy is not a thing — clients use CONNECT")
    }

    // MARK: - Auth

    func testAuthAcceptsMatchingBasicCredentials() {
        let b64 = Data("dev:s3cr:et".utf8).base64EncodedString()  // password containing ':'
        let h = head("CONNECT x:443 HTTP/1.1\r\nProxy-Authorization: Basic \(b64)")
        XCTAssertTrue(proxyAuthorized(h, username: "dev", password: "s3cr:et"))
    }

    func testAuthRejectsMissingWrongSchemeAndWrongCredentials() {
        XCTAssertFalse(proxyAuthorized(head("CONNECT x:443 HTTP/1.1"), username: "dev", password: "p"))
        XCTAssertFalse(proxyAuthorized(head("CONNECT x:443 HTTP/1.1\r\nProxy-Authorization: Bearer zzz"),
                                       username: "dev", password: "p"))
        XCTAssertFalse(proxyAuthorized(head("CONNECT x:443 HTTP/1.1\r\nProxy-Authorization: Basic ***"),
                                       username: "dev", password: "p"), "not even base64")
        let wrong = Data("dev:nope".utf8).base64EncodedString()
        XCTAssertFalse(proxyAuthorized(head("CONNECT x:443 HTTP/1.1\r\nProxy-Authorization: Basic \(wrong)"),
                                       username: "dev", password: "p"))
    }

    // MARK: - Responses

    func testResponses() {
        XCTAssertEqual(String(decoding: proxyResponse200(), as: UTF8.self),
                       "HTTP/1.1 200 Connection Established\r\n\r\n")
        let s407 = String(decoding: proxyResponse407(), as: UTF8.self)
        XCTAssertTrue(s407.hasPrefix("HTTP/1.1 407 "))
        XCTAssertTrue(s407.contains("Proxy-Authenticate: Basic realm=\"DevDeck\"\r\n"))
        XCTAssertTrue(String(decoding: proxyResponse400(), as: UTF8.self).hasPrefix("HTTP/1.1 400 "))
        XCTAssertTrue(String(decoding: proxyResponse502(), as: UTF8.self).hasPrefix("HTTP/1.1 502 "))
    }

    // MARK: - Session lines (must round-trip through the gost parser)

    func testSessionLinesParseBackThroughGostParser() {
        let open = builtInSessionLine(open: true, client: "192.168.31.42:55904", sid: "abc123", port: 9999)
        let close = builtInSessionLine(open: false, client: "192.168.31.42:55904", sid: "abc123", port: 9999)
        XCTAssertEqual(parseGostLogLine(open), .sessionOpened(client: "192.168.31.42:55904", sid: "abc123"))
        XCTAssertEqual(parseGostLogLine(close), .sessionClosed(sid: "abc123"))
    }
}

private extension ProxyRequestKind {
    /// Compact assertion helper: "host:port" for either routed kind, nil for .bad.
    var hostPort: String? {
        switch self {
        case .connect(let h, let p), .absoluteForm(let h, let p, _): return "\(h):\(p)"
        case .bad: return nil
        }
    }
}
