//
//  ToolSecretsKeychain.swift
//  osaurus
//
//  Secure Keychain storage for plugin secrets (API keys, tokens, etc.).
//

import Foundation
import Security

/// Keychain wrapper for secure plugin secret storage
public enum ToolSecretsKeychain {
    private static let service = "ai.osaurus.tools"

    // MARK: - Secret Management

    /// Save a secret value for a plugin
    /// - Parameters:
    ///   - value: The secret value to store
    ///   - id: The secret identifier (e.g., "api_key")
    ///   - pluginId: The plugin identifier (e.g., "dev.example.weather")
    /// - Returns: True if the secret was saved successfully
    @discardableResult
    public static func saveSecret(_ value: String, id: String, for pluginId: String) -> Bool {
        let account = "\(pluginId).\(id)"
        guard let valueData = value.data(using: .utf8) else { return false }

        // Delete any existing secret first
        deleteSecret(id: id, for: pluginId)

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

    /// Retrieve a secret value for a plugin
    /// - Parameters:
    ///   - id: The secret identifier (e.g., "api_key")
    ///   - pluginId: The plugin identifier (e.g., "dev.example.weather")
    /// - Returns: The secret value if found, nil otherwise
    public static func getSecret(id: String, for pluginId: String) -> String? {
        let account = "\(pluginId).\(id)"

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

    /// Check if a secret exists for a plugin
    /// - Parameters:
    ///   - id: The secret identifier (e.g., "api_key")
    ///   - pluginId: The plugin identifier (e.g., "dev.example.weather")
    /// - Returns: True if the secret exists
    public static func hasSecret(id: String, for pluginId: String) -> Bool {
        return getSecret(id: id, for: pluginId) != nil
    }

    /// Delete a secret for a plugin
    /// - Parameters:
    ///   - id: The secret identifier (e.g., "api_key")
    ///   - pluginId: The plugin identifier (e.g., "dev.example.weather")
    /// - Returns: True if the secret was deleted or didn't exist
    @discardableResult
    public static func deleteSecret(id: String, for pluginId: String) -> Bool {
        let account = "\(pluginId).\(id)"

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Delete all secrets for a plugin
    /// - Parameter pluginId: The plugin identifier
    public static func deleteAllSecrets(for pluginId: String) {
        let accountPrefix = "\(pluginId)."

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

    /// Get all secrets for a plugin as a dictionary
    /// - Parameter pluginId: The plugin identifier
    /// - Returns: Dictionary mapping secret IDs to their values
    public static func getAllSecrets(for pluginId: String) -> [String: String] {
        let accountPrefix = "\(pluginId)."

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
        ]

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess,
            let items = result as? [[String: Any]]
        else {
            return [:]
        }

        var secrets: [String: String] = [:]
        for item in items {
            if let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(accountPrefix),
                let data = item[kSecValueData as String] as? Data,
                let value = String(data: data, encoding: .utf8)
            {
                // Extract the secret ID from the account (remove plugin prefix)
                let secretId = String(account.dropFirst(accountPrefix.count))
                secrets[secretId] = value
            }
        }

        return secrets
    }

    /// Check if all required secrets are configured for a plugin
    /// - Parameters:
    ///   - specs: Array of secret specifications
    ///   - pluginId: The plugin identifier
    /// - Returns: True if all required secrets have values
    public static func hasAllRequiredSecrets(specs: [PluginManifest.SecretSpec], for pluginId: String) -> Bool {
        for spec in specs where spec.required {
            if !hasSecret(id: spec.id, for: pluginId) {
                return false
            }
        }
        return true
    }

    /// Get the list of missing required secrets
    /// - Parameters:
    ///   - specs: Array of secret specifications
    ///   - pluginId: The plugin identifier
    /// - Returns: Array of missing required secret specs
    public static func getMissingRequiredSecrets(
        specs: [PluginManifest.SecretSpec],
        for pluginId: String
    ) -> [PluginManifest.SecretSpec] {
        return specs.filter { spec in
            spec.required && !hasSecret(id: spec.id, for: pluginId)
        }
    }
}
