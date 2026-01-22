import Foundation
import Security

final class KeychainService {
    static let shared = KeychainService()

    private let service: String
    private let accessGroup: String?

    init(service: String = Config.keychainService, accessGroup: String? = Config.keychainAccessGroup) {
        self.service = service
        self.accessGroup = accessGroup
    }

    // MARK: - Public Methods

    func save(key: String, value: String) throws {
        guard let data = value.data(using: .utf8) else {
            throw ImageHostError.keychainError(status: errSecParam)
        }

        // First, try to delete any existing item
        try? delete(key: key)

        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemAdd(query as CFDictionary, nil)

        guard status == errSecSuccess else {
            throw ImageHostError.keychainError(status: status)
        }
    }

    func load(key: String) throws -> String? {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        switch status {
        case errSecSuccess:
            guard let data = result as? Data,
                  let string = String(data: data, encoding: .utf8) else {
                return nil
            }
            return string
        case errSecItemNotFound:
            return nil
        default:
            throw ImageHostError.keychainError(status: status)
        }
    }

    func delete(key: String) throws {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key
        ]

        if let accessGroup = accessGroup {
            query[kSecAttrAccessGroup as String] = accessGroup
        }

        let status = SecItemDelete(query as CFDictionary)

        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw ImageHostError.keychainError(status: status)
        }
    }

    // MARK: - Convenience Methods for Upload Token

    func saveUploadToken(_ token: String) throws {
        try save(key: Config.uploadTokenKey, value: token)
    }

    func loadUploadToken() throws -> String? {
        try load(key: Config.uploadTokenKey)
    }

    func deleteUploadToken() throws {
        try delete(key: Config.uploadTokenKey)
    }
}
