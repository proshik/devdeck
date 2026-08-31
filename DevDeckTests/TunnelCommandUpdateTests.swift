import XCTest
@testable import DevDeck

/// `TunnelCommandUpdate.plan` — the pure decision behind editing a remote proxy: rewrite the
/// tunnel command's destination/SOCKS port, or leave a hand-edited command alone. No store, no
/// `ProxyManager`, no UI.
final class TunnelCommandUpdateTests: XCTestCase {

    // MARK: - RemoteProxy.tunnelCommandString / parsedDestination — the shared shape

    func testTunnelCommandStringMatchesMakeTunnelCommand() {
        let remote = RemoteProxy(name: "vds", socksPort: 1080)
        let generated = remote.makeTunnelCommand(destination: "user@vds")
        XCTAssertEqual(generated.command,
                       RemoteProxy.tunnelCommandString(destination: "user@vds", socksPort: 1080))
    }

    func testParsedDestinationRecoversWhatWasGenerated() {
        let command = RemoteProxy.tunnelCommandString(destination: "user@vds", socksPort: 1080)
        XCTAssertEqual(RemoteProxy.parsedDestination(fromTunnelCommand: command, socksPort: 1080),
                       "user@vds")
    }

    func testParsedDestinationRecoversTrailingFlagsToo() {
        // Anything typed into the original "destination" box — including trailing ssh options —
        // round-trips as one string, because it was written in as one string to begin with.
        let command = RemoteProxy.tunnelCommandString(
            destination: "user@vds -o ServerAliveInterval=30", socksPort: 1080)
        XCTAssertEqual(RemoteProxy.parsedDestination(fromTunnelCommand: command, socksPort: 1080),
                       "user@vds -o ServerAliveInterval=30")
    }

    func testParsedDestinationFailsWhenThePortDoesNotMatch() {
        let command = RemoteProxy.tunnelCommandString(destination: "user@vds", socksPort: 1080)
        // Parsing against the WRONG port (e.g. the proxy's socksPort drifted from the command) must
        // not silently produce a garbled destination.
        XCTAssertNil(RemoteProxy.parsedDestination(fromTunnelCommand: command, socksPort: 2080))
    }

    func testParsedDestinationFailsWhenTheShapeWasEditedBeforeTheDestination() {
        // A flag inserted BETWEEN the fixed prefix and the destination is exactly what hand-editing
        // looks like — the literal prefix no longer matches.
        let handEdited = "ssh -v -N -D 127.0.0.1:1080 user@vds"
        XCTAssertNil(RemoteProxy.parsedDestination(fromTunnelCommand: handEdited, socksPort: 1080))
    }

    // MARK: - plan()

    func testPlanRewritesWhenTheCommandStillMatchesTheOldGeneratedShape() {
        let oldExpected = RemoteProxy.tunnelCommandString(destination: "user@old-vds", socksPort: 1080)

        let plan = TunnelCommandUpdate.plan(current: oldExpected, expectedForOldValues: oldExpected,
                                            newDestination: "user@new-vds", newSocksPort: 2080)

        XCTAssertEqual(plan, .rewrite(
            RemoteProxy.tunnelCommandString(destination: "user@new-vds", socksPort: 2080)))
    }

    func testPlanRewritesEvenWhenOnlyThePortChanges() {
        // The SOCKS port is baked into the command's `-D` flag too — a port-only edit must still
        // regenerate it, or the running tunnel and the proxy's own `socksPort` field desync.
        let oldExpected = RemoteProxy.tunnelCommandString(destination: "user@vds", socksPort: 1080)

        let plan = TunnelCommandUpdate.plan(current: oldExpected, expectedForOldValues: oldExpected,
                                            newDestination: "user@vds", newSocksPort: 2080)

        XCTAssertEqual(plan, .rewrite(RemoteProxy.tunnelCommandString(destination: "user@vds", socksPort: 2080)))
    }

    func testPlanIsHandEditedWhenTheStoredCommandDiffersFromTheOldGeneratedShape() {
        let expectedForOldValues = RemoteProxy.tunnelCommandString(destination: "user@vds", socksPort: 1080)
        // The user added a jump host directly in the command editor.
        let handEdited = "ssh -N -D 127.0.0.1:1080 -J jump.example.com user@vds"

        let plan = TunnelCommandUpdate.plan(current: handEdited, expectedForOldValues: expectedForOldValues,
                                            newDestination: "user@new-vds", newSocksPort: 1080)

        XCTAssertEqual(plan, .handEdited)
    }

    func testPlanIsHandEditedOnAnyMismatchEvenAOneCharacterOne() {
        let expectedForOldValues = RemoteProxy.tunnelCommandString(destination: "user@vds", socksPort: 1080)
        let currentlyStored = RemoteProxy.tunnelCommandString(destination: "user@vds ", socksPort: 1080)

        let plan = TunnelCommandUpdate.plan(current: currentlyStored, expectedForOldValues: expectedForOldValues,
                                            newDestination: "user@new-vds", newSocksPort: 1080)

        XCTAssertEqual(plan, .handEdited)
    }

    func testPlanRewriteIsANoOpStringWhenNothingActuallyChanged() {
        // Opening the sheet and saving without touching anything must not fabricate a "change".
        let expected = RemoteProxy.tunnelCommandString(destination: "user@vds", socksPort: 1080)

        let plan = TunnelCommandUpdate.plan(current: expected, expectedForOldValues: expected,
                                            newDestination: "user@vds", newSocksPort: 1080)

        XCTAssertEqual(plan, .rewrite(expected))
    }
}
