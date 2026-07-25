import XCTest
@testable import DevDeck

/// The file the terminal helper reads. Pure text — the writer itself is exercised through
/// `FakeProxyEnvFile` in the manager's tests, so nothing here touches the real ~/.config.
final class ProxyEnvFileTests: XCTestCase {

    func testContentsCarryTheTwoKeysTheHelperReads() {
        let text = proxyEnvFileContents(url: "http://192.168.31.117:9999", lanPrefix: "192.168.31")

        XCTAssertTrue(text.contains("DEVDECK_PROXY_URL=http://192.168.31.117:9999"))
        XCTAssertTrue(text.contains("DEVDECK_PROXY_LAN=192.168.31"))
    }

    func testContentsAreNotShellExecutable() {
        // The helper reads keys instead of sourcing the file, so a tampered file can't run code.
        // Emitting `export` lines would invite someone to "simplify" the helper into `source`.
        let text = proxyEnvFileContents(url: "http://h:1", lanPrefix: "10.0.0")

        XCTAssertFalse(text.contains("export "))
        XCTAssertTrue(text.hasPrefix("#"), "leads with the do-not-edit header")
        XCTAssertTrue(text.hasSuffix("\n"), "trailing newline so `sed` sees the last line")
    }

    func testURLIsBuiltByTheSameHelperAsTheInjectedEnv() {
        // One builder for both paths — otherwise escaping could drift between them.
        let url = proxyURL(host: "h", port: 1, user: "u@corp", pass: "p:a@ss/word")

        XCTAssertEqual(url, "http://u%40corp:p%3Aa%40ss%2Fword@h:1")
        XCTAssertEqual(proxyEnv(host: "h", port: 1, user: "u@corp", pass: "p:a@ss/word")["HTTPS_PROXY"], url)
    }

    func testURLWithoutCredentials() {
        XCTAssertEqual(proxyURL(host: "192.168.31.117", port: 9999, user: nil, pass: nil),
                       "http://192.168.31.117:9999")
        XCTAssertEqual(proxyURL(host: "h", port: 1, user: "", pass: "p"), "http://h:1",
                       "an empty user must not produce a ':p@' prefix")
    }
}
