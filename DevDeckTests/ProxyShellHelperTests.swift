import XCTest
@testable import DevDeck

/// The `dp` helper actually run under zsh. Only the REFUSAL paths are asserted: they are the
/// security-relevant branches and they are deterministic. The success path depends on the machine's
/// live network — asserting it here would just re-implement the interface scan and prove nothing;
/// it is verified by hand (`dp curl -s https://api.ipify.org`).
final class ProxyShellHelperTests: XCTestCase {

    private var home: URL!

    override func setUpWithError() throws {
        home = FileManager.default.temporaryDirectory
            .appendingPathComponent("DevDeckTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: home.appendingPathComponent(".config/devdeck"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func writeEnvFile(_ contents: String) throws {
        try contents.write(to: home.appendingPathComponent(".config/devdeck/proxy.env"),
                           atomically: true, encoding: .utf8)
    }

    /// Runs the snippet under zsh with a sandboxed HOME, then `dp /bin/echo MARKER`.
    private func runHelper() throws -> (status: Int32, output: String) {
        let script = proxyShellHelperSnippet + "\ndp /bin/echo MARKER\n"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-c", script]
        process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    func testRefusesWhenTheEnvFileIsMissing() throws {
        let result = try runHelper()

        XCTAssertNotEqual(result.status, 0, "no active proxy must not silently run the command direct")
        XCTAssertFalse(result.output.contains("MARKER"), "the wrapped command must not have run")
    }

    func testRefusesOnADifferentNetwork() throws {
        // TEST-NET-3 (RFC 5737) — cannot match any real interface on this machine.
        try writeEnvFile("""
        DEVDECK_PROXY_URL=http://203.0.113.9:9999
        DEVDECK_PROXY_LAN=203.0.113

        """)

        let result = try runHelper()

        XCTAssertNotEqual(result.status, 0, "a remembered address must not be dialled off its own LAN")
        XCTAssertFalse(result.output.contains("MARKER"))
    }

    func testRefusesWhenTheEnvFileIsIncomplete() throws {
        try writeEnvFile("DEVDECK_PROXY_URL=http://192.168.31.117:9999\n")

        let result = try runHelper()

        XCTAssertNotEqual(result.status, 0)
        XCTAssertFalse(result.output.contains("MARKER"))
    }

    func testSnippetDoesNotSourceTheEnvFile() {
        // Sourcing would turn a data file into a code-execution surface.
        XCTAssertFalse(proxyShellHelperSnippet.contains("source "))
        XCTAssertFalse(proxyShellHelperSnippet.contains(". $f"))
    }

    func testSnippetScansInterfacesInsteadOfTheDefaultRoute() {
        // Under a full-tunnel corporate VPN the default route is a utun*, whose address
        // `ipconfig getifaddr` does not report — deriving the interface from it would break the
        // check in exactly the situation this helper exists for.
        XCTAssertFalse(proxyShellHelperSnippet.contains("route -n get default"))
        XCTAssertTrue(proxyShellHelperSnippet.contains("ifconfig -l"))
    }
}
