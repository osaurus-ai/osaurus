//
//  RemoteProviderKeychain.swift
//  osaurus
//
//  Secure Keychain storage for remote OpenAI-compatible provider credentials.
//

import Foundation
import Security

/// Keychain wrapper for secure remote provider credential storage
public enum RemoteProviderKeychain {
    private static let service = "ai.osaurus.remote"

    // MARK: - API Key Management

    /// Save an API key for a provider ID
    @discardableResult
    public static func saveAPIKey(_ apiKey: String, for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).apiKey"
        guard let keyData = apiKey.data(using: .utf8) else { return false }

        // Delete any existing key first
        deleteAPIKey(for: providerId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: keyData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        return status == errSecSuccess
    }

    /// Retrieve an API key for a provider ID
    public static func getAPIKey(for providerId: UUID) -> String? {
        let account = "\(providerId.uuidString).apiKey"

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
            let apiKey = String(data: data, encoding: .utf8)
        else {
            return nil
        }

        return apiKey
    }

    /// Delete an API key for a provider ID
    @discardableResult
    public static func deleteAPIKey(for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).apiKey"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Check if an API key exists for a provider ID
    public static func hasAPIKey(for providerId: UUID) -> Bool {
        return getAPIKey(for: providerId) != nil
    }

    // MARK: - Header Secret Management

    /// Save a secret header value for a provider
    @discardableResult
    public static func saveHeaderSecret(_ value: String, key: String, for providerId: UUID) -> Bool {
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
    public static func getHeaderSecret(key: String, for providerId: UUID) -> String? {
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
    public static func deleteHeaderSecret(key: String, for providerId: UUID) -> Bool {
        let account = "\(providerId.uuidString).header.\(key)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Delete all secrets for a provider (API key + all header secrets)
    public static func deleteAllSecrets(for providerId: UUID) {
        // Delete API key
        deleteAPIKey(for: providerId)

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
