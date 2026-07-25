import Foundation
import Security

/// Keychain account keys. Usernames live in config.json (they're not secret and must be
/// hand-editable); passwords only ever live here.
enum ProxyCredentialAccount {
    /// The password this machine's own `gost` listener demands from clients.
    static let share = "proxy-share:\(ProxyShare.daemonID.uuidString)"
    /// The password used when connecting to a discovered proxy, keyed by its Bonjour identity.
    static func client(_ bonjourName: String) -> String { "proxy-client:\(bonjourName)" }
}

/// Password storage for proxy credentials. Behind a protocol so routing/share resolution is tested
/// with an in-memory fake — no Keychain prompts in unit tests.
protocol ProxyCredentialStore: Sendable {
    func password(for account: String) -> String?
    /// Store a password; passing nil (or an empty string) removes the entry.
    func setPassword(_ password: String?, for account: String)
}

/// The real store — a generic password item per account under one service.
/// Upsert is delete-then-add: simpler than `SecItemUpdate` and idempotent when nothing is stored yet.
struct KeychainProxyCredentialStore: ProxyCredentialStore {
    static let service = "DevDeck.proxy"

    init() {}

    func password(for account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound {
                DiagnosticLog.shared.log("Keychain read failed for \(account) (status \(status))", level: .warn)
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func setPassword(_ password: String?, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let password, !password.isEmpty else { return }

        var add = base
        add[kSecValueData as String] = Data(password.utf8)
        // The app must read this without a prompt right after login (it starts gost at launch).
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        if status != errSecSuccess {
            DiagnosticLog.shared.log("Keychain write failed for \(account) (status \(status))", level: .warn)
        }
    }
}
