import XCTest
@testable import DevDeck

/// Keychain round-trip for proxy passwords. Uses account names unique to each run so a leftover
/// item can never make a later run pass or fail spuriously, and cleans up after itself.
final class ProxyCredentialStoreTests: XCTestCase {

    private let store = KeychainProxyCredentialStore()
    private var account: String!

    override func setUp() {
        super.setUp()
        account = "proxy-test:\(UUID().uuidString)"
    }

    override func tearDown() {
        store.setPassword(nil, for: account)
        super.tearDown()
    }

    func testRoundTripAndOverwriteAndDelete() throws {
        XCTAssertNil(store.password(for: account), "nothing stored yet")

        store.setPassword("s3cret", for: account)
        XCTAssertEqual(store.password(for: account), "s3cret")

        // Upsert is delete-then-add — a second write must replace, not duplicate.
        store.setPassword("rotated", for: account)
        XCTAssertEqual(store.password(for: account), "rotated")

        store.setPassword(nil, for: account)
        XCTAssertNil(store.password(for: account), "nil removes the entry")
    }

    func testEmptyPasswordRemovesTheEntry() {
        store.setPassword("s3cret", for: account)
        store.setPassword("", for: account)

        XCTAssertNil(store.password(for: account), "an empty field means 'no password', not an empty one")
    }

    func testAccountsAreIsolated() {
        let other = "proxy-test:\(UUID().uuidString)"
        defer { store.setPassword(nil, for: other) }

        store.setPassword("mine", for: account)
        store.setPassword("theirs", for: other)

        XCTAssertEqual(store.password(for: account), "mine")
        XCTAssertEqual(store.password(for: other), "theirs")
    }

    func testAccountKeysSeparateHostAndClientRoles() {
        // One machine can BOTH share (its own listener password) and consume (a peer's password).
        XCTAssertNotEqual(ProxyCredentialAccount.share, ProxyCredentialAccount.client("personal-mac"))
        XCTAssertEqual(ProxyCredentialAccount.share, "proxy-share:\(ProxyShare.daemonID.uuidString)")
        XCTAssertNotEqual(ProxyCredentialAccount.client("a"), ProxyCredentialAccount.client("b"))
    }
}
