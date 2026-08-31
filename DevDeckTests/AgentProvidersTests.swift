import XCTest
@testable import DevDeck

/// `AgentProviders.makeDefault()` is the one place "the agents this build knows about, in
/// resolution order" is spelled out — `ClaudeTabsModel` and `TabRestorer` both default to it.
/// Nothing else in the suite constructs a `ClaudeTabsModel` or a `TabRestorer` without overriding
/// `providers` with fakes, so this factory itself was reachable by no test at all: dropping a
/// provider from it — the exact mistake the factory exists to prevent — would go unnoticed.
final class AgentProvidersTests: XCTestCase {
    func testMakeDefaultListsBothProvidersInResolutionOrder() {
        XCTAssertEqual(AgentProviders.makeDefault().map(\.id), ["opencode", "claude"],
                       "opencode must be tried before Claude, the fallback that claims every tab")
    }
}
