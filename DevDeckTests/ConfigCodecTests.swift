import XCTest
@testable import DevDeck

/// Tests for the pure (de)serialization layer of `ConfigCodec` — no filesystem involved.
/// This is the core requirement of Phase 1: round-trip JSON.
final class ConfigCodecTests: XCTestCase {

    // MARK: round-trip

    func testRoundTripPreservesAllFields() throws {
        let daemon = Command(
            id: UUID(),
            name: "port-forward",
            command: "kubectl port-forward svc/foo 8080:80",
            workingDirectory: "/Users/x/project",
            isDaemon: true,
            needsSudo: false,
            env: ["KUBECONFIG": "/tmp/kc", "FOO": "bar"]
        )
        let plain = Command(
            id: UUID(),
            name: "colima stop",
            command: "colima stop",
            workingDirectory: nil,
            isDaemon: false,
            needsSudo: false,
            env: [:]
        )
        let chain = Chain(
            id: UUID(),
            name: "Full restart",
            commandIDs: [plain.id, daemon.id],
            stopOnError: true
        )
        let config = Config(schemaVersion: 1, commands: [daemon, plain], chains: [chain])

        let data = try ConfigCodec.encode(config)
        let decoded = try ConfigCodec.decode(data)

        XCTAssertEqual(decoded, config)
    }

    func testCommandAppsToQuitRoundTripAndResilience() throws {
        let command = Command(
            id: UUID(), name: "build", command: "just dev-build",
            appsToQuit: [
                AppRef(bundleID: "com.google.Chrome", name: "Google Chrome"),
                AppRef(bundleID: "com.tinyspeck.slackmacgap", name: "Slack"),
            ]
        )
        let decoded = try ConfigCodec.decode(ConfigCodec.encode(Config(commands: [command])))
        XCTAssertEqual(decoded.commands.first?.appsToQuit, command.appsToQuit)

        // Missing key → empty list (resilient decode).
        let minimal = try ConfigCodec.decode(Data(#"{ "commands": [ { "name": "x", "command": "echo" } ] }"#.utf8))
        XCTAssertEqual(minimal.commands.first?.appsToQuit, [])
    }

    func testEncodeIsByteStable() throws {
        let config = Config(
            schemaVersion: 1,
            commands: [Command(id: UUID(), name: "a", command: "echo")],
            chains: []
        )
        let first = try ConfigCodec.encode(config)
        let second = try ConfigCodec.encode(config)
        XCTAssertEqual(first, second, "sortedKeys must produce deterministic output")
    }

    // MARK: decode resilience (hand-edited files)

    func testDecodeToleratesMissingOptionalCommandFields() throws {
        // Minimal command: only name and command are provided.
        let json = Data("""
        { "commands": [ { "name": "echo", "command": "echo hi" } ] }
        """.utf8)

        let config = try ConfigCodec.decode(json)

        let c = try XCTUnwrap(config.commands.first)
        XCTAssertEqual(c.name, "echo")
        XCTAssertEqual(c.command, "echo hi")
        XCTAssertNil(c.workingDirectory)
        XCTAssertFalse(c.isDaemon)
        XCTAssertFalse(c.needsSudo)
        XCTAssertEqual(c.env, [:])
    }

    func testDecodeToleratesMissingTopLevelKeys() throws {
        // Missing chains and schemaVersion keys.
        let json = Data("""
        { "commands": [] }
        """.utf8)

        let config = try ConfigCodec.decode(json)

        XCTAssertEqual(config.chains, [])
        XCTAssertEqual(config.schemaVersion, Config.currentSchemaVersion)
    }

    func testDecodeToleratesMissingChainFields() throws {
        let json = Data("""
        { "commands": [], "chains": [ { "name": "Full restart" } ] }
        """.utf8)

        let config = try ConfigCodec.decode(json)

        let chain = try XCTUnwrap(config.chains.first)
        XCTAssertEqual(chain.name, "Full restart")
        XCTAssertEqual(chain.commandIDs, [])
        XCTAssertTrue(chain.stopOnError, "stopOnError defaults to true")
    }

    func testSettingsRoundTripAndDefault() throws {
        // missing settings → both flags default to true
        let json = Data(#"{"commands":[],"chains":[]}"#.utf8)
        XCTAssertTrue(try ConfigCodec.decode(json).settings.vmMemoryMonitoring)
        XCTAssertTrue(try ConfigCodec.decode(json).settings.minikubeMemoryMonitoring)

        // explicit false round-trips correctly
        var cfg = Config.empty
        cfg.settings.vmMemoryMonitoring = false
        cfg.settings.minikubeMemoryMonitoring = false
        let data = try ConfigCodec.encode(cfg)
        XCTAssertFalse(try ConfigCodec.decode(data).settings.vmMemoryMonitoring)
        XCTAssertFalse(try ConfigCodec.decode(data).settings.minikubeMemoryMonitoring)
    }

    func testDecodeGeneratesIDWhenMissing() throws {
        let json = Data("""
        { "commands": [ { "name": "a", "command": "x" }, { "name": "b", "command": "y" } ] }
        """.utf8)

        let config = try ConfigCodec.decode(json)

        XCTAssertEqual(config.commands.count, 2)
        XCTAssertNotEqual(config.commands[0].id, config.commands[1].id, "id is generated and unique")
    }
}
