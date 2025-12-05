//
//  MCPProviderKeychain.swift
//  osaurus
//
//  Secure Keychain storage for MCP provider tokens.
//

import Foundation
import Security

/// Keychain wrapper for secure MCP provider token storage
enum MCPProviderKeychain {
    private static let service = "ai.osaurus.mcp"

    // MARK: - Token Management

    /// Save a token for a provider ID
    @discardableResult
    static func saveToken(_ token: String, for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).token"
        guard let tokenData = token.data(using: .utf8) else { return false }

        // Delete any existing token first
        deleteToken(for: providerId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: tokenData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve a token for a provider ID
    static func getToken(for providerId: UUID) -> String? {
        let account = "\(providerId.uuidString).token"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let token = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return token
    }

    /// Delete a token for a provider ID
    @discardableResult
    static func deleteToken(for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).token"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if a token exists for a provider ID
    static func hasToken(for providerId: UUID) -> Bool {
        return getToken(for: providerId) != nil
    }

    // MARK: - Header Secret Management

    /// Save a secret header value for a provider
    @discardableResult
    static func saveHeaderSecret(_ value: String, key: String, for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).header.\(key)"
        guard let valueData = value.data(using: .utf8) else { return false }

        // Delete any existing value first
        deleteHeaderSecret(key: key, for: providerId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve a secret header value for a provider
    static func getHeaderSecret(key: String, for providerId: UUID) -> String? {
        let account = "\(providerId.uuidString).header.\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let data = result as? Data,
            let value = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return value
    }

    /// Delete a secret header value for a provider
    @discardableResult
    static func deleteHeaderSecret(key: String, for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).header.\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Delete all secrets for a provider (token + all header secrets)
    static func deleteAllSecrets(for providerId: UUID) {
        // Delete token
        deleteToken(for: providerId)

        // Delete all header secrets by querying with prefix
        let accountPrefix = "\(providerId.uuidString)."

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let items = result as? [[String: Any]]
        else {
            return
        }

        for item in items {
            if let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(accountPrefix)
            {
                let deleteQuery: [String: Any] = [
                    kSecClass as String: kSecClassGenericPassword,
                    kSecAttrService as String: service,
                    kSecAttrAccount as String: account,
                ]
                SecItemDelete(deleteQuery as CFDictionary)
            }
        }
    }
}
