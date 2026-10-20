import Foundation
import Security

@MainActor
protocol MailboxCredentials {
    func read(server: URL) -> String?
    func write(_ token: String, server: URL) throws
    func delete(server: URL) throws
}

struct KeychainStore: MailboxCredentials {
    private let service = "com.pearliminal.ios"
    private let account = "mailbox-token"
    private let legacyServer: URL?

    init(defaults: UserDefaults = .standard) {
        if let saved = defaults.string(forKey: "apiBaseURL") {
            legacyServer = APIClient.validatedBaseURL(saved)
        } else { legacyServer = APIClient.productionURL }
    }

    func read(server: URL) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(account).\(server.absoluteString)",
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        if SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
           let data = result as? Data { return String(data: data, encoding: .utf8) }
        guard server == APIClient.productionURL, legacyServer == server else { return nil }
        var legacy = query
        legacy[kSecAttrAccount as String] = account
        guard SecItemCopyMatching(legacy as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data, let token = String(data: data, encoding: .utf8) else { return nil }
        do {
            try write(token, server: server)
            SecItemDelete(legacy as CFDictionary)
            return token
        } catch { return nil }
    }

    func write(_ token: String, server: URL) throws {
        let data = Data(token.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(account).\(server.absoluteString)",
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            attributes.forEach { insert[$0.key] = $0.value }
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    func delete(server: URL) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "\(account).\(server.absoluteString)",
        ]
        // A leftover legacy entry must not resurrect a production session after sign-out.
        if server == APIClient.productionURL, legacyServer == server {
            var legacy = query
            legacy[kSecAttrAccount as String] = account
            let status = SecItemDelete(legacy as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
        }
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

private struct KeychainError: LocalizedError {
    let status: OSStatus
    var errorDescription: String? { "Could not access the mailbox token (Keychain error \(status))." }
}
