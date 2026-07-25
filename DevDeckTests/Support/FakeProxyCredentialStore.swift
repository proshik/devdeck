import Foundation
@testable import DevDeck

/// In-memory credential store — exercises the auth paths without touching the real Keychain
/// (which would prompt, and would leak state between test runs).
final class FakeProxyCredentialStore: ProxyCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var passwords: [String: String] = [:]

    init(_ initial: [String: String] = [:]) {
        passwords = initial
    }

    func password(for account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return passwords[account]
    }

    func setPassword(_ password: String?, for account: String) {
        lock.lock(); defer { lock.unlock() }
        if let password, !password.isEmpty {
            passwords[account] = password
        } else {
            passwords.removeValue(forKey: account)
        }
    }
}
