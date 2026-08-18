import XCTest
@testable import DevDeck

/// The pure env builder + the LAN-interface picker — both are pure, so they're tested directly.
final class ProxyRoutingTests: XCTestCase {

    // MARK: env builder

    func testEnvWithoutCredentials() {
        let env = proxyEnv(host: "192.168.1.42", port: 9999, user: nil, pass: nil)

        XCTAssertEqual(env["HTTPS_PROXY"], "http://192.168.1.42:9999")
        XCTAssertEqual(env["HTTP_PROXY"], "http://192.168.1.42:9999")
        XCTAssertEqual(env["ALL_PROXY"], "http://192.168.1.42:9999")
    }

    func testEnvEmitsBothCasesBecauseCLIsDisagree() {
        let env = proxyEnv(host: "10.0.0.5", port: 8080, user: nil, pass: nil)

        for key in ["HTTPS_PROXY", "HTTP_PROXY", "ALL_PROXY", "https_proxy", "http_proxy", "all_proxy"] {
            XCTAssertEqual(env[key], "http://10.0.0.5:8080", "\(key) must be set — many CLIs read only one case")
        }
        XCTAssertEqual(env["NO_PROXY"], "localhost,127.0.0.1,::1")
        XCTAssertEqual(env["no_proxy"], "localhost,127.0.0.1,::1")
        XCTAssertEqual(env.count, 8)
    }

    func testEnvWithCredentials() {
        let env = proxyEnv(host: "192.168.1.42", port: 9999, user: "dev", pass: "s3cret")

        XCTAssertEqual(env["HTTPS_PROXY"], "http://dev:s3cret@192.168.1.42:9999")
        XCTAssertEqual(env["https_proxy"], "http://dev:s3cret@192.168.1.42:9999")
    }

    func testEmptyUsernameIsTreatedAsNoCredentials() {
        let env = proxyEnv(host: "h", port: 1, user: "", pass: "p")
        XCTAssertEqual(env["HTTPS_PROXY"], "http://h:1", "an empty user must not produce a ':p@' prefix")
    }

    func testCredentialsWithSpecialCharactersAreEscaped() {
        // A password containing @ or : would otherwise split the URL at the wrong place.
        let env = proxyEnv(host: "h", port: 1, user: "u@corp", pass: "p:a@ss/word")
        XCTAssertEqual(env["HTTPS_PROXY"], "http://u%40corp:p%3Aa%40ss%2Fword@h:1")
    }

    // MARK: LAN interface picking (the correctness-critical part)

    func testPicksEnAndNeverTheVPNTunnel() {
        // The sharing Mac holds a full-tunnel VPN, so utun* addresses are always present.
        // Announcing one would publish an unreachable address and every peer would time out.
        let picked = pickLANIPv4(from: [
            NetworkInterfaceAddress(name: "utun4", address: "10.8.0.2"),
            NetworkInterfaceAddress(name: "en0", address: "192.168.1.42"),
            NetworkInterfaceAddress(name: "lo0", address: "127.0.0.1"),
        ])

        XCTAssertEqual(picked, "192.168.1.42")
    }

    func testExcludesAWDLBridgeAndLoopback() {
        let picked = pickLANIPv4(from: [
            NetworkInterfaceAddress(name: "awdl0", address: "169.254.10.1"),
            NetworkInterfaceAddress(name: "llw0", address: "169.254.10.2"),
            NetworkInterfaceAddress(name: "bridge0", address: "192.168.64.1"),
            NetworkInterfaceAddress(name: "lo0", address: "127.0.0.1"),
            NetworkInterfaceAddress(name: "en1", address: "192.168.1.77"),
        ])

        XCTAssertEqual(picked, "192.168.1.77")
    }

    func testSkipsSelfAssignedLinkLocalOnEn() {
        // en0 with a 169.254.x address means DHCP failed — it isn't reachable as a LAN address.
        let picked = pickLANIPv4(from: [
            NetworkInterfaceAddress(name: "en0", address: "169.254.55.1"),
            NetworkInterfaceAddress(name: "en5", address: "192.168.1.90"),
        ])

        XCTAssertEqual(picked, "192.168.1.90")
    }

    func testPrefersLowestNumberedInterfaceNaturally() {
        // Natural (not lexicographic) order: en2 must win over en10.
        let picked = pickLANIPv4(from: [
            NetworkInterfaceAddress(name: "en10", address: "192.168.1.10"),
            NetworkInterfaceAddress(name: "en2", address: "192.168.1.2"),
        ])

        XCTAssertEqual(picked, "192.168.1.2")
    }

    func testNoLANInterfaceYieldsNil() {
        XCTAssertNil(pickLANIPv4(from: [NetworkInterfaceAddress(name: "utun0", address: "10.8.0.2")]))
        XCTAssertNil(pickLANIPv4(from: []))
    }

    // MARK: LAN scope of a remembered endpoint

    func testLANPrefixIsTheFirstThreeOctets() {
        XCTAssertEqual(lanPrefix(of: "192.168.31.117"), "192.168.31")
        XCTAssertEqual(lanPrefix(of: "10.0.0.9"), "10.0.0")
        XCTAssertEqual(lanPrefix(of: "192.168.1.1"), "192.168.1")
    }

    func testLANPrefixRejectsAnythingThatIsNotADottedQuad() {
        // A nil prefix makes a cached endpoint unusable — the safe direction.
        XCTAssertNil(lanPrefix(of: ""))
        XCTAssertNil(lanPrefix(of: "192.168.31"), "three octets is not an address")
        XCTAssertNil(lanPrefix(of: "192.168.31.117.5"), "five octets is not an address")
        XCTAssertNil(lanPrefix(of: "192.168.31.999"), "999 is not an octet")
        XCTAssertNil(lanPrefix(of: "192.168.31."), "empty last octet")
        XCTAssertNil(lanPrefix(of: "fe80::1"), "IPv6")
        XCTAssertNil(lanPrefix(of: "macbook.local"), "a hostname")
    }

    // MARK: TXT record

    func testTXTRecordNeverCarriesAPassword() {
        let ad = ProxyAdvertisement(serviceName: "personal-mac", port: 9999, authRequired: true,
                                    host: "192.168.1.42", exitIP: "78.40.193.132")
        let txt = proxyTXTRecord(ad)

        XCTAssertEqual(txt["auth"], "1", "clients learn that credentials are NEEDED…")
        for (key, value) in txt {
            XCTAssertFalse(key.lowercased().contains("pass"), "…but no password key is ever announced: \(key)")
            XCTAssertFalse(value.contains("s3cret"), "value \(value) must not carry secrets")
        }
        XCTAssertEqual(txt["host"], "192.168.1.42")
        XCTAssertEqual(txt["port"], "9999")
        XCTAssertEqual(txt["proto"], "http+socks")
        XCTAssertEqual(txt["vpnip"], "78.40.193.132")
        XCTAssertEqual(txt["v"], "1")
    }

    func testTXTRecordCarriesTheEngineProto() {
        var ad = ProxyAdvertisement(serviceName: "mac", port: 9999, authRequired: false,
                                    host: "192.168.31.5", exitIP: nil)
        ad.proto = "http"
        XCTAssertEqual(proxyTXTRecord(ad)["proto"], "http")
        // The default stays the historical value — a gost share announces exactly what it used to
        // (asserted in full by testTXTRecordNeverCarriesAPassword above).
    }

    func testTXTOmitsExitIPWhenUnknown() {
        let ad = ProxyAdvertisement(serviceName: "m", port: 1, authRequired: false, host: "h", exitIP: nil)
        XCTAssertNil(proxyTXTRecord(ad)["vpnip"])
        XCTAssertEqual(proxyTXTRecord(ad)["auth"], "0")
    }

    func testTXTRoundTripsThroughParsing() {
        let ad = ProxyAdvertisement(serviceName: "personal-mac", port: 9999, authRequired: true,
                                    host: "192.168.1.42", exitIP: "78.40.193.132")
        let parsed = parseProxyTXT(name: ad.serviceName, txt: proxyTXTRecord(ad))

        XCTAssertEqual(parsed, DiscoveredProxy(name: "personal-mac", host: "192.168.1.42", port: 9999,
                                               authRequired: true, exitIP: "78.40.193.132",
                                               proto: "http+socks", schema: 1))
    }

    func testParseRejectsRecordWithoutUsableEndpoint() {
        XCTAssertNil(parseProxyTXT(name: "x", txt: ["port": "9999"]), "no host")
        XCTAssertNil(parseProxyTXT(name: "x", txt: ["host": "1.2.3.4"]), "no port")
        XCTAssertNil(parseProxyTXT(name: "x", txt: ["host": "", "port": "9999"]), "empty host")
        XCTAssertNil(parseProxyTXT(name: "x", txt: ["host": "1.2.3.4", "port": "nope"]), "unparseable port")
    }

    /// `host` comes from anyone on the network and ends up in the persisted endpoint cache and,
    /// unescaped, in a `KEY=value` line of `proxy.env`. Requiring a dotted quad deletes that whole
    /// class of worry: nothing carrying a newline, a space or an `=` can reach either.
    func testParseRejectsAHostThatIsNotADottedQuad() {
        XCTAssertNil(parseProxyTXT(name: "x", txt: ["host": "evil.example.com", "port": "9999"]),
                     "a hostname is not an endpoint we know how to validate")
        XCTAssertNil(parseProxyTXT(name: "x", txt: ["host": "1.2.3", "port": "9999"]), "too few octets")
        XCTAssertNil(parseProxyTXT(name: "x", txt: ["host": "1.2.3.999", "port": "9999"]), "octet out of range")
        XCTAssertNil(parseProxyTXT(name: "x", txt: ["host": "192.168.1.9\nDEVDECK_PROXY_LAN=10.0.0",
                                                   "port": "9999"]),
                     "an injected second env line must never reach proxy.env")
        XCTAssertNotNil(parseProxyTXT(name: "x", txt: ["host": "192.168.1.9", "port": "9999"]),
                        "sanity: a real LAN address still parses")
    }
}
