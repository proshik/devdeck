import XCTest
@testable import DevDeck

/// Config persistence for the proxy feature. The point of these: a v1 file written before this
/// feature existed must keep loading unchanged, because the decode is resilient key-by-key rather
/// than migration-based.
final class ProxyConfigCodecTests: XCTestCase {

    func testV1FileWithoutProxyDecodesToDefaults() throws {
        let v1 = Data("""
        {
          "schemaVersion": 1,
          "commands": [ { "name": "build", "command": "just build" } ],
          "chains": [],
          "settings": { "vmMemoryMonitoring": true }
        }
        """.utf8)

        let config = try ConfigCodec.decode(v1)

        XCTAssertEqual(config.schemaVersion, 1, "the file's own version is preserved, not rewritten on read")
        XCTAssertEqual(config.proxy, ProxyShare(), "a missing proxy block falls back to defaults")
        XCTAssertFalse(config.settings.proxyShareEnabled)
        XCTAssertFalse(config.settings.proxyDiscoveryEnabled)
        XCTAssertNil(config.settings.activeProxyName)
        XCTAssertNil(config.settings.activeProxyUsername)
        XCTAssertEqual(config.commands.first?.routeThroughProxy, false)
    }

    func testCurrentSchemaVersionIsTwo() {
        XCTAssertEqual(Config.currentSchemaVersion, 2)
        XCTAssertEqual(Config.empty.schemaVersion, 2)
        // A file with no schemaVersion at all is treated as current.
        let bare = try! ConfigCodec.decode(Data(#"{"commands":[]}"#.utf8))
        XCTAssertEqual(bare.schemaVersion, 2)
    }

    func testProxyShareRoundTrips() throws {
        let share = ProxyShare(port: 8888, authEnabled: true, username: "dev", serviceName: "personal-mac")
        let decoded = try ConfigCodec.decode(ConfigCodec.encode(Config(proxy: share)))

        XCTAssertEqual(decoded.proxy, share)
    }

    func testProxyShareToleratesPartialHandEdits() throws {
        let partial = try ConfigCodec.decode(Data(#"{"commands":[],"proxy":{"port":7777}}"#.utf8))

        XCTAssertEqual(partial.proxy.port, 7777)
        XCTAssertFalse(partial.proxy.authEnabled)
        XCTAssertEqual(partial.proxy.username, "")
        XCTAssertEqual(partial.proxy.serviceName, "")
    }

    func testProxySettingsRoundTrip() throws {
        var config = Config.empty
        config.settings.proxyShareEnabled = true
        config.settings.proxyDiscoveryEnabled = true
        config.settings.activeProxyName = "personal-mac"
        config.settings.activeProxyUsername = "dev"

        let decoded = try ConfigCodec.decode(ConfigCodec.encode(config))

        XCTAssertEqual(decoded.settings, config.settings)
    }

    func testRouteThroughProxyRoundTripsAndDefaultsToFalse() throws {
        let command = Command(id: UUID(), name: "claude", command: "claude", routeThroughProxy: true)
        let decoded = try ConfigCodec.decode(ConfigCodec.encode(Config(commands: [command])))
        XCTAssertEqual(decoded.commands.first?.routeThroughProxy, true)

        let minimal = try ConfigCodec.decode(Data(#"{ "commands": [ { "name": "x", "command": "echo" } ] }"#.utf8))
        XCTAssertEqual(minimal.commands.first?.routeThroughProxy, false)
    }

    func testNoPasswordIsEverWrittenToTheConfigFile() throws {
        // Structural guard: the model has no field a password could land in.
        var config = Config.empty
        config.proxy = ProxyShare(port: 9999, authEnabled: true, username: "dev")
        config.settings.activeProxyUsername = "dev"
        let json = String(data: try ConfigCodec.encode(config), encoding: .utf8) ?? ""

        XCTAssertFalse(json.lowercased().contains("password"))
        XCTAssertTrue(json.contains("\"username\""), "usernames are fine in the config — passwords are not")
    }

    func testRememberedEndpointRoundTrips() throws {
        var config = Config.empty
        config.settings.activeProxyName = "personal-mac"
        config.settings.activeProxyHost = "192.168.31.117"
        config.settings.activeProxyPort = 9999
        config.settings.activeProxyAuthRequired = true
        config.settings.activeProxyLANPrefix = "192.168.31"

        let decoded = try ConfigCodec.decode(ConfigCodec.encode(config))

        XCTAssertEqual(decoded.settings.activeProxyHost, "192.168.31.117")
        XCTAssertEqual(decoded.settings.activeProxyPort, 9999)
        XCTAssertEqual(decoded.settings.activeProxyAuthRequired, true)
        XCTAssertEqual(decoded.settings.activeProxyLANPrefix, "192.168.31")
    }

    func testFileWithoutRememberedEndpointDecodesToDefaults() throws {
        // A config written by 0.5.0 has the active proxy but no cached endpoint.
        let older = Data(#"{"commands":[],"settings":{"activeProxyName":"personal-mac"}}"#.utf8)

        let config = try ConfigCodec.decode(older)

        XCTAssertEqual(config.settings.activeProxyName, "personal-mac")
        XCTAssertNil(config.settings.activeProxyHost)
        XCTAssertNil(config.settings.activeProxyPort)
        XCTAssertFalse(config.settings.activeProxyAuthRequired)
        XCTAssertNil(config.settings.activeProxyLANPrefix)
        XCTAssertEqual(config.schemaVersion, 2, "adding optional keys does not bump the schema")
    }
}
