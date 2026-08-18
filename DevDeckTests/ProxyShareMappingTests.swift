import XCTest
@testable import DevDeck

/// `ProxyShare` → synthetic daemon `Command` + the gost config file: the mapping that lets the
/// EXISTING supervision engine run gost with no new supervision code, and keeps the credentials off
/// the command line.
final class ProxyShareMappingTests: XCTestCase {

    // MARK: - The command line

    func testCommandCarriesOnlyTheConfigPath() throws {
        let share = ProxyShare(port: 9999, authEnabled: true, username: "dev", engine: .gost)
        let command = try XCTUnwrap(
            share.toCommand(gostPath: "/opt/homebrew/bin/gost", configPath: "/tmp/gost.json"))

        XCTAssertEqual(command.command, "'/opt/homebrew/bin/gost' -C '/tmp/gost.json'")
        XCTAssertTrue(command.isDaemon)
        XCTAssertTrue(command.watchdogEnabled, "the watchdog IS the auto-restart the manual setup lacked")
        XCTAssertEqual(command.port, 9999, "carrying the port enables the occupied-port panel for free")
    }

    func testCommandLineNeverCarriesCredentials() throws {
        // macOS lets every local account read any process's full argv, so a password on the command
        // line is a password published to the machine. It belongs in the 0600 config file instead.
        let share = ProxyShare(port: 8888, authEnabled: true, username: "dev", engine: .gost)
        let command = try XCTUnwrap(
            share.toCommand(gostPath: "/opt/homebrew/bin/gost", configPath: "/tmp/gost.json"))

        XCTAssertFalse(command.command.contains("dev"))
        XCTAssertFalse(command.command.contains("auto://"))
    }

    func testPathsAreShellQuoted() throws {
        // The real config path is under "Application Support" — a space in an unquoted command line
        // would split it into two arguments.
        let command = try XCTUnwrap(ProxyShare(engine: .gost).toCommand(
            gostPath: "/opt/homebrew/bin/gost",
            configPath: "/Users/x/Library/Application Support/DevDeck/gost.json"))

        XCTAssertEqual(command.command,
                       "'/opt/homebrew/bin/gost' -C '/Users/x/Library/Application Support/DevDeck/gost.json'")
    }

    func testCommandIsStableAcrossAPasswordChange() throws {
        // It used to embed the password, so changing one changed the string. Adoption of this
        // daemon does not work either way (`findOrphan` compares a pre-shell string against
        // post-shell argv, and these quotes never reach argv) — the point here is only that the
        // command no longer varies with a secret.
        let path = ProxyShare.configURL.path
        let before = try XCTUnwrap(ProxyShare(port: 9999, authEnabled: true, username: "dev", engine: .gost)
            .toCommand(gostPath: "/g", configPath: path))
        let after = try XCTUnwrap(ProxyShare(port: 9999, authEnabled: true, username: "dev", engine: .gost)
            .toCommand(gostPath: "/g", configPath: path))

        XCTAssertEqual(before.command, after.command)
    }

    func testDaemonIDIsStableAndUsedForSupervision() throws {
        let first = try XCTUnwrap(ProxyShare(port: 1).toCommand(gostPath: "/g", configPath: "/c"))
        let second = try XCTUnwrap(ProxyShare(port: 2, authEnabled: true, username: "u")
            .toCommand(gostPath: "/g", configPath: "/c"))

        XCTAssertEqual(first.id, ProxyShare.daemonID)
        XCTAssertEqual(second.id, ProxyShare.daemonID,
                       "one stable id — supervision state and orphan adoption agree across sessions")
    }

    func testDaemonNameCarriesNoPasswordSoLogsStayClean() throws {
        let command = try XCTUnwrap(ProxyShare(port: 9999, authEnabled: true, username: "dev", engine: .gost)
            .toCommand(gostPath: "/opt/homebrew/bin/gost", configPath: "/c"))

        // DiagnosticLog logs `command.name`, never `command.command`.
        XCTAssertEqual(command.name, L10n.proxyShareDaemonName)
    }

    // MARK: - Engine

    func testEngineDefaultsToBuiltInWhenAbsent() throws {
        let json = #"{"port": 9999}"#
        let share = try JSONDecoder().decode(ProxyShare.self, from: Data(json.utf8))
        XCTAssertEqual(share.engine, .builtIn)
    }

    func testEngineDecodesAndSurvivesRoundTrip() throws {
        var share = ProxyShare()
        share.engine = .gost
        let data = try JSONEncoder().encode(share)
        let back = try JSONDecoder().decode(ProxyShare.self, from: data)
        XCTAssertEqual(back.engine, .gost)
    }

    func testUnknownEngineStringFallsBackToBuiltIn() throws {
        // A config written by a NEWER DevDeck must not fail the whole file here.
        let json = #"{"engine": "socks-magic"}"#
        let share = try JSONDecoder().decode(ProxyShare.self, from: Data(json.utf8))
        XCTAssertEqual(share.engine, .builtIn)
    }

    func testBuiltInCommandUsesMarkerAndRawPath() throws {
        var share = ProxyShare(port: 9999)
        share.engine = .builtIn
        let command = try XCTUnwrap(share.toCommand(gostPath: nil,
                                                    configPath: "/tmp/dir with space/gost.json"))
        // No shell ever parses the marker command, so the path travels verbatim, unquoted.
        XCTAssertEqual(command.command, "devdeck:proxy-listen -C /tmp/dir with space/gost.json")
        XCTAssertEqual(command.id, ProxyShare.daemonID)
        XCTAssertTrue(command.isDaemon)
        XCTAssertTrue(command.watchdogEnabled)
        XCTAssertEqual(command.port, 9999)
        XCTAssertEqual(command.name, L10n.proxyShareDaemonNameBuiltIn)
    }

    func testGostCommandNilWithoutBinary() {
        var share = ProxyShare()
        share.engine = .gost
        XCTAssertNil(share.toCommand(gostPath: nil, configPath: "/tmp/gost.json"))
    }

    func testBuiltInCommandIgnoresMissingGost() {
        var share = ProxyShare()
        share.engine = .builtIn
        XCTAssertNotNil(share.toCommand(gostPath: nil, configPath: "/tmp/gost.json"))
    }

    // MARK: - The generated config

    func testOpenListenerConfig() {
        let json = ProxyShare(port: 9999).gostConfigJSON(password: nil)

        XCTAssertEqual(json, #"{"services":[{"addr":":9999","handler":{"type":"auto"},"#
            + #""listener":{"type":"tcp"},"name":"devdeck-proxy"}]}"#,
            "gost v3 auto:// serves HTTP+SOCKS on one port; an absent auth block means open")
    }

    func testAuthListenerConfig() {
        let json = ProxyShare(port: 8888, authEnabled: true, username: "dev")
            .gostConfigJSON(password: "s3cret")

        XCTAssertEqual(json, #"{"services":[{"addr":":8888","handler":{"auth":"#
            + #"{"password":"s3cret","username":"dev"},"type":"auto"},"#
            + #""listener":{"type":"tcp"},"name":"devdeck-proxy"}]}"#)
    }

    func testAuthWithoutUsernameStaysOpen() {
        // Auth on but no username → no half-formed credential block that gost would reject.
        let json = ProxyShare(port: 9999, authEnabled: true, username: "")
            .gostConfigJSON(password: "ignored")

        XCTAssertEqual(json?.contains("auth"), false)
        XCTAssertEqual(json?.contains("ignored"), false)
    }

    func testPasswordDisabledWhenAuthOff() {
        let json = ProxyShare(port: 9999, authEnabled: false, username: "dev")
            .gostConfigJSON(password: "s3cret")

        XCTAssertEqual(json?.contains("s3cret"), false,
                       "auth off means no credentials, even if one is still stored in the Keychain")
    }

    func testHostileCredentialsAreEscapedNotExecuted() {
        // The bug this whole change undoes: these characters used to close a shell literal and run
        // the remainder. JSON encoding is what makes that structurally impossible now.
        let json = ProxyShare(port: 9999, authEnabled: true, username: #"al'ice"x"#)
            .gostConfigJSON(password: "p'w\"d$(touch /tmp/pwn)\nmore")

        let unwrapped = try? XCTUnwrap(json)
        XCTAssertNotNil(unwrapped)
        // A raw newline or an unescaped quote would break the document; both are escaped.
        XCTAssertFalse(unwrapped?.contains("\n") ?? true, "a literal newline would tear the JSON")
        XCTAssertEqual(unwrapped?.contains(#"\"x"#), true, "the quote is escaped, not terminating")
        // And it still parses back to exactly what was put in.
        let data = Data((unwrapped ?? "").utf8)
        let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let services = parsed?["services"] as? [[String: Any]]
        let auth = (services?.first?["handler"] as? [String: Any])?["auth"] as? [String: String]
        XCTAssertEqual(auth?["username"], #"al'ice"x"#)
        XCTAssertEqual(auth?["password"], "p'w\"d$(touch /tmp/pwn)\nmore")
    }

    func testConfigPathSitsBesideTheConfigFile() {
        XCTAssertEqual(ProxyShare.configURL.lastPathComponent, "gost.json")
        XCTAssertEqual(ProxyShare.configURL.deletingLastPathComponent(),
                       CommandStore.defaultConfigURL.deletingLastPathComponent(),
                       "one owner-only directory holds everything DevDeck persists")
    }

    // MARK: - Naming

    func testEffectiveServiceNameFallsBackToHostName() {
        XCTAssertEqual(ProxyShare(serviceName: "  ").effectiveServiceName, ProxyShare.defaultServiceName)
        XCTAssertEqual(ProxyShare(serviceName: "personal-mac").effectiveServiceName, "personal-mac")
        XCTAssertFalse(ProxyShare.defaultServiceName.hasSuffix(".local"),
                       "Bonjour appends .local itself — announcing it twice yields host.local.local")
    }
}
