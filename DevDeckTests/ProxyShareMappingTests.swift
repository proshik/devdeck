import XCTest
@testable import DevDeck

/// `ProxyShare` → synthetic daemon `Command`: the mapping that lets the EXISTING supervision engine
/// run gost with no new supervision code.
final class ProxyShareMappingTests: XCTestCase {

    func testOpenListenerArgv() {
        let share = ProxyShare(port: 9999)
        let command = share.toCommand(gostPath: "/opt/homebrew/bin/gost", password: nil)

        XCTAssertEqual(command.command, "/opt/homebrew/bin/gost -L 'auto://:9999'",
                       "gost v3 auto:// serves HTTP+SOCKS on one port; no credentials when auth is off")
        XCTAssertTrue(command.isDaemon)
        XCTAssertTrue(command.watchdogEnabled, "the watchdog IS the auto-restart the manual setup lacked")
        XCTAssertEqual(command.port, 9999, "carrying the port enables the occupied-port panel for free")
    }

    func testAuthListenerEmbedsCredentials() {
        let share = ProxyShare(port: 8888, authEnabled: true, username: "dev")
        let command = share.toCommand(gostPath: "/usr/local/bin/gost", password: "s3cret")

        XCTAssertEqual(command.command, "/usr/local/bin/gost -L 'auto://dev:s3cret@:8888'")
    }

    func testAuthWithoutUsernameStaysOpen() {
        // Auth on but no username → no half-formed credential prefix that gost would reject.
        let share = ProxyShare(port: 9999, authEnabled: true, username: "")
        let command = share.toCommand(gostPath: "/opt/homebrew/bin/gost", password: "ignored")

        XCTAssertEqual(command.command, "/opt/homebrew/bin/gost -L 'auto://:9999'")
    }

    func testDaemonIDIsStableAndUsedForSupervision() {
        let first = ProxyShare(port: 1).toCommand(gostPath: "/g", password: nil)
        let second = ProxyShare(port: 2, authEnabled: true, username: "u")
            .toCommand(gostPath: "/g", password: "p")

        XCTAssertEqual(first.id, ProxyShare.daemonID)
        XCTAssertEqual(second.id, ProxyShare.daemonID,
                       "one stable id — supervision state and orphan adoption agree across sessions")
    }

    func testDaemonNameCarriesNoPasswordSoLogsStayClean() {
        let command = ProxyShare(port: 9999, authEnabled: true, username: "dev")
            .toCommand(gostPath: "/opt/homebrew/bin/gost", password: "s3cret")

        // DiagnosticLog logs `command.name`, never `command.command` — that's what keeps the
        // password out of devdeck.log.
        XCTAssertFalse(command.name.contains("s3cret"))
        XCTAssertEqual(command.name, L10n.proxyShareDaemonName)
    }

    func testEffectiveServiceNameFallsBackToHostName() {
        XCTAssertEqual(ProxyShare(serviceName: "  ").effectiveServiceName, ProxyShare.defaultServiceName)
        XCTAssertEqual(ProxyShare(serviceName: "personal-mac").effectiveServiceName, "personal-mac")
        XCTAssertFalse(ProxyShare.defaultServiceName.hasSuffix(".local"),
                       "Bonjour appends .local itself — announcing it twice yields host.local.local")
    }
}
