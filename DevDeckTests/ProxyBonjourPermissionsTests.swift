import XCTest
@testable import DevDeck

/// Guard for the feature's biggest risk: on macOS 15, Bonjour browsing and publishing fail
/// SILENTLY (empty results, no prompt, no error) when the Local Network keys are missing from
/// Info.plist. A regression here would look like "discovery just doesn't find anything".
/// In a hosted test `Bundle.main` is DevDeck.app, so this checks the shipped plist.
final class ProxyBonjourPermissionsTests: XCTestCase {

    func testLocalNetworkUsageDescriptionIsPresent() throws {
        let description = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSLocalNetworkUsageDescription") as? String,
            "NSLocalNetworkUsageDescription must be in Info.plist or the permission prompt never appears"
        )
        XCTAssertFalse(description.isEmpty)
    }

    func testBonjourServicesDeclaresOurServiceType() throws {
        let services = try XCTUnwrap(
            Bundle.main.object(forInfoDictionaryKey: "NSBonjourServices") as? [String],
            "NSBonjourServices must be in Info.plist or NWBrowser returns nothing"
        )
        XCTAssertTrue(services.contains(proxyBonjourServiceType),
                      "the declared service type must match the one the browser and advertiser use")
    }

    func testServiceTypeIsAValidBonjourTCPType() {
        XCTAssertEqual(proxyBonjourServiceType, "_devdeck-proxy._tcp")
        XCTAssertTrue(proxyBonjourServiceType.hasPrefix("_"))
        XCTAssertTrue(proxyBonjourServiceType.hasSuffix("._tcp"))
    }
}
