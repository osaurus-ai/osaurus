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
    private static let testStoreLock = NSLock()
    private nonisolated(unsafe) static var testStore: [String: String] = [:]

    // MARK: - Agent-Scoped Secret Management

    @discardableResult
    public static func saveSecret(_ value: String, id: String, for pluginId: String, agentId: UUID) -> Bool {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock { testStore[account] = value }
            return true
        }
        guard let valueData = value.data(using: .utf8) else { return false }
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        return Keychain.write(service: service, account: account, data: valueData)
    }

    public static func getSecret(id: String, for pluginId: String, agentId: UUID) -> String? {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            return testStoreLock.withLock { testStore[account] }
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        return Keychain.read(service: service, account: account)
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func hasSecret(id: String, for pluginId: String, agentId: UUID) -> Bool {
        return getSecret(id: id, for: pluginId, agentId: agentId) != nil
    }

    @discardableResult
    public static func deleteSecret(id: String, for pluginId: String, agentId: UUID) -> Bool {
        let account = agentAccount(agentId: agentId, pluginId: pluginId, key: id)
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock { _ = testStore.removeValue(forKey: account) }
            return true
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
        return Keychain.delete(service: service, account: account)
    }

    public static func deleteAllSecrets(for pluginId: String, agentId: UUID) {
        let accountPrefix = agentAccountPrefix(agentId: agentId, pluginId: pluginId)
        deleteAllMatchingPrefix(accountPrefix)
    }

    /// Delete all agent-scoped secrets for a plugin across every agent.
    public static func deleteAllSecretsAllAgents(for pluginId: String) {
        if KeychainQueryHelpers.disablesKeychainForProcess { return }
        let allItems = fetchAllItems(attributesOnly: true)
        let suffix = ".\(pluginId)."
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.contains(suffix)
            else { continue }
            Keychain.delete(service: service, account: account)
        }
    }

    /// Delete every per-agent secret across all plugins for the given
    /// `agentId`. Called from `AgentManager.delete(id:)` so deleting an
    /// agent does not leave stale `bot_token` / OAuth credentials /
    /// per-agent webhook URLs accumulating in Keychain Access. Sweeps
    /// any account whose prefix is `"{agentId}."`.
    public static func deleteAllSecrets(forAgent agentId: UUID) {
        deleteAllMatchingPrefix("\(agentId.uuidString).")
    }

    public static func getAllSecrets(for pluginId: String, agentId: UUID) -> [String: String] {
        let accountPrefix = agentAccountPrefix(agentId: agentId, pluginId: pluginId)

        let allItems = fetchAllItems(attributesOnly: true)
        var secrets: [String: String] = [:]
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(accountPrefix)
            else { continue }
            let secretId = String(account.dropFirst(accountPrefix.count))
            if let value = getSecret(id: secretId, for: pluginId, agentId: agentId) {
                secrets[secretId] = value
            }
        }

        return secrets
    }

    /// Per-agent secrets merged on top of `Agent.defaultId` (Plugins-tab
    /// writes act as global defaults; Agents-tab writes override per-key).
    public static func resolvedSecretsWithDefaults(pluginId: String, agentId: UUID) -> [String: String] {
        resolvedSecretsMerging(pluginId: pluginId, primary: agentId, defaults: Agent.defaultId)
    }

    /// Two-id merge primitive: `primary` agent's secrets overlaid on `defaults`.
    public static func resolvedSecretsMerging(pluginId: String, primary: UUID, defaults: UUID) -> [String: String] {
        let defaultDict = getAllSecrets(for: pluginId, agentId: defaults)
        if primary == defaults { return defaultDict }
        let primaryDict = getAllSecrets(for: pluginId, agentId: primary)
        var merged = defaultDict
        for (k, v) in primaryDict { merged[k] = v }
        return merged
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
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            return testStoreLock.withLock {
                testStore.map { account, value in
                    var item: [String: Any] = [kSecAttrAccount as String: account]
                    if !attributesOnly {
                        item[kSecValueData as String] = Data(value.utf8)
                    }
                    return item
                }
            }
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return [] }
        return Keychain.fetchAll(service: service, returnData: !attributesOnly)
    }

    private static func deleteAllMatchingPrefix(_ prefix: String) {
        if KeychainQueryHelpers.usesInMemoryKeychainStoreForTests {
            testStoreLock.withLock {
                let matchingAccounts = testStore.keys.filter { $0.hasPrefix(prefix) }
                for account in matchingAccounts {
                    testStore.removeValue(forKey: account)
                }
            }
            return
        }
        if KeychainQueryHelpers.disablesKeychainForProcess { return }
        let allItems = fetchAllItems(attributesOnly: true)
        for item in allItems {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(prefix)
            else { continue }
            Keychain.delete(service: service, account: account)
        }
    }
}
