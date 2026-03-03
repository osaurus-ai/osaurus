//
//  ToolSecretsKeychain.swift
//  osaurus
//
//  Secure Keychain storage for plugin secrets (API keys, tokens, etc.).
//

import Foundation
import Security

/// Keychain wrapper for secure plugin secret storage.
/// All config is agent-scoped: account format is `"{agentId}.{pluginId}.{key}"`.
public enum ToolSecretsKeychain {
    private static let service = "ai.osaurus.tools"

    // MARK: - Agent-Scoped Secret Management

    @discardableResult
    public static func saveSecret(_ value: String, id: String, for pluginId: String, agentId: UUID) -> Bool {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        guard let valueData = value.data(using: .utf8) else { return false }

        deleteSecret(id: id, for: pluginId, agentId: agentId)

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

    public static func getSecret(id: String, for pluginId: String, agentId: UUID) -> String? {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)

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

    public static func hasSecret(id: String, for pluginId: String, agentId: UUID) -> Bool {
        return getSecret(id: id, for: pluginId, agentId: agentId) != nil
    }

    @discardableResult
    public static func deleteSecret(id: String, for pluginId: String, agentId: UUID) -> Bool {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]

        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    public static func deleteAllSecrets(for pluginId: String, agentId: UUID) {
        let accountPrefix = agentAccountPrefix(agentId: agentId, pluginId: pluginId)
        deleteAllMatchingPrefix(accountPrefix)
    }

    /// Delete all agent-scoped secrets for a plugin across every agent.
    public static func deleteAllSecretsAllAgents(for pluginId: String) {
        let allItems = fetchAllItems(attributesOnly: true)
        let suffix = ".\(pluginId)."
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.contains(suffix)
            else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }

    public static func getAllSecrets(for pluginId: String, agentId: UUID) -> [String: String] {
        let accountPrefix = agentAccountPrefix(agentId: agentId, pluginId: pluginId)

        let allItems = fetchAllItems(attributesOnly: false)
        var secrets: [String: String] = [:]
        for item in allItems {
            if let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(accountPrefix),
                let data = item[kSecValueData as String] as? Data,
                let value = String(data: data, encoding: .utf8)
            {
                let secretId = String(account.dropFirst(accountPrefix.count))
                secrets[secretId] = value
            }
        }

        return secrets
    }

    public static func hasAllRequiredSecrets(specs: [PluginManifest.SecretSpec], for pluginId: String, agentId: UUID)
        -> Bool
    {
        for spec in specs where spec.required {
            if !hasSecret(id: spec.id, for: pluginId, agentId: agentId) {
                return false
            }
        }
        return true
    }

    public static func getMissingRequiredSecrets(
        specs: [PluginManifest.SecretSpec],
        for pluginId: String,
        agentId: UUID
    ) -> [PluginManifest.SecretSpec] {
        return specs.filter { spec in
            spec.required && !hasSecret(id: spec.id, for: pluginId, agentId: agentId)
        }
    }

    // MARK: - Legacy Cleanup (non-agent-scoped entries)

    /// Delete all legacy (non-agent-scoped) entries matching `"{pluginId}.*"`.
    /// Used during plugin uninstall to clean up any remaining pre-migration data.
    public static func deleteAllSecrets(for pluginId: String) {
        deleteAllMatchingPrefix("\(pluginId).")
    }

    // MARK: - Migration Support

    /// Returns all legacy (non-agent-scoped) keychain entries for a given plugin.
    /// Legacy accounts match `"{pluginId}.{key}"` but NOT `"{uuid}.{pluginId}.{key}"`.
    public static func legacySecrets(for pluginId: String) -> [String: String] {
        let legacyPrefix = "\(pluginId)."
        let allItems = fetchAllItems(attributesOnly: false)

        var secrets: [String: String] = [:]
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(legacyPrefix),
                !isAgentScopedAccount(account),
                let data = item[kSecValueData as String] as? Data,
                let value = String(data: data, encoding: .utf8)
            else { continue }

            secrets[String(account.dropFirst(legacyPrefix.count))] = value
        }
        return secrets
    }

    /// Delete all legacy (non-agent-scoped) entries for a plugin.
    public static func deleteLegacySecrets(for pluginId: String) {
        let legacyPrefix = "\(pluginId)."
        let allItems = fetchAllItems(attributesOnly: true)

        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(legacyPrefix),
                !isAgentScopedAccount(account)
            else { continue }

            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }

    // MARK: - Internal Helpers

    private static func agentAccount(agentId: UUID, pluginId: String, key: String) -> String {
        "\(agentId.uuidString).\(pluginId).\(key)"
    }

    private static func agentAccountPrefix(agentId: UUID, pluginId: String) -> String {
        "\(agentId.uuidString).\(pluginId)."
    }

    /// UUID pattern: 8-4-4-4-12 hex at the start of the account string.
    private static func isAgentScopedAccount(_ account: String) -> Bool {
        let uuidLength = 36  // "XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX"
        guard account.count > uuidLength,
            account[account.index(account.startIndex, offsetBy: uuidLength)] == "."
        else { return false }
        let prefix = String(account.prefix(uuidLength))
        return UUID(uuidString: prefix) != nil
    }

    private static func fetchAllItems(attributesOnly: Bool) -> [[String: Any]] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]
        if !attributesOnly {
            query[kSecReturnData as String] = true
        }

        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)

        guard status == errSecSuccess, let items = result as? [[String: Any]] else {
            return []
        }
        return items
    }

    private static func deleteAllMatchingPrefix(_ prefix: String) {
        let allItems = fetchAllItems(attributesOnly: true)
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(prefix)
            else { continue }
            let deleteQuery: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(deleteQuery as CFDictionary)
        }
    }
}
