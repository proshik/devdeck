import XCTest
@testable import DevDeck

/// Table tests for the pure local-port extractor used to pre-fill `Command.port`.
final class PortParserTests: XCTestCase {

    func testKubectlPortForwardPair() {
        XCTAssertEqual(PortParser.localPort(in: "kubectl port-forward svc/foo 8080:80"), 8080)
        XCTAssertEqual(PortParser.localPort(in: "kubectl -n dev port-forward pod/db 5433:5432 --address 0.0.0.0"), 5433)
    }

    func testKubectlRandomLocalPortIsNil() {
        // Bare ":80" means "pick a random local port" — nothing to check.
        XCTAssertNil(PortParser.localPort(in: "kubectl port-forward pod/x :80"))
    }

    func testSSHLocalForward() {
        XCTAssertEqual(PortParser.localPort(in: "ssh -L 5432:db.internal:5432 bastion"), 5432)
        XCTAssertEqual(PortParser.localPort(in: "ssh -L localhost:5432:db.internal:5432 bastion"), 5432)
        XCTAssertEqual(PortParser.localPort(in: "ssh -N -L 127.0.0.1:8443:svc:443 jump"), 8443)
    }

    func testExplicitPortFlag() {
        XCTAssertEqual(PortParser.localPort(in: "some-server --port 3000"), 3000)
        XCTAssertEqual(PortParser.localPort(in: "some-server --port=3000"), 3000)
        XCTAssertEqual(PortParser.localPort(in: "caddy --listen 2015"), 2015)
    }

    func testDockerPublishPair() {
        XCTAssertEqual(PortParser.localPort(in: "docker run -p 8080:80 nginx"), 8080)
        XCTAssertEqual(PortParser.localPort(in: "docker run -p 127.0.0.1:8080:80 nginx"), 8080)
    }

    func testLonePFlagIsAmbiguous() {
        // `psql -p 5432` connects TO a port; it doesn't listen on one.
        XCTAssertNil(PortParser.localPort(in: "psql -p 5432 -h localhost"))
    }

    func testNoPort() {
        XCTAssertNil(PortParser.localPort(in: "echo hello"))
        XCTAssertNil(PortParser.localPort(in: ""))
    }

    func testOutOfRangePort() {
        XCTAssertNil(PortParser.localPort(in: "some-server --port 99999"))
        XCTAssertNil(PortParser.localPort(in: "some-server --port 0"))
    }
}
