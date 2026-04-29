//
//  AgentSecretsKeychain.swift
//  osaurus
//
//  Secure Keychain storage for agent-level secrets (API keys, tokens, etc.).
//  Unlike ToolSecretsKeychain which is plugin-scoped, this stores secrets
//  per-agent only, making them accessible to any sandbox plugin.
//

import Foundation
import Security

/// Keychain wrapper for agent-scoped secret storage.
/// Account format: `"{agentId}.{key}"` — no plugin scoping.
public enum AgentSecretsKeychain {
    private static let service = "ai.osaurus.agent-secrets"

    #if DEBUG
        private static let inMemoryStoreLock = NSLock()
        nonisolated(unsafe) private static var inMemoryStoreForTesting: [String: String]?

        static func _withInMemoryStoreForTesting<T>(
            _ body: () throws -> T
        ) rethrows -> T {
            inMemoryStoreLock.lock()
            let previous = inMemoryStoreForTesting
            inMemoryStoreForTesting = [:]
            inMemoryStoreLock.unlock()

            defer {
                inMemoryStoreLock.lock()
                inMemoryStoreForTesting = previous
                inMemoryStoreLock.unlock()
            }

            return try body()
        }

        private static func testingSave(_ value: String, account: String) -> (enabled: Bool, saved: Bool) {
            inMemoryStoreLock.lock()
            defer { inMemoryStoreLock.unlock() }
            guard inMemoryStoreForTesting != nil else {
                return (enabled: false, saved: false)
            }
            inMemoryStoreForTesting?[account] = value
            return (enabled: true, saved: true)
        }

        private static func testingGet(account: String) -> (enabled: Bool, value: String?) {
            inMemoryStoreLock.lock()
            defer { inMemoryStoreLock.unlock() }
            guard let store = inMemoryStoreForTesting else {
                return (enabled: false, value: nil)
            }
            return (enabled: true, value: store[account])
        }

        private static func testingDelete(account: String) -> (enabled: Bool, deleted: Bool) {
            inMemoryStoreLock.lock()
            defer { inMemoryStoreLock.unlock() }
            guard inMemoryStoreForTesting != nil else {
                return (enabled: false, deleted: false)
            }
            inMemoryStoreForTesting?[account] = nil
            return (enabled: true, deleted: true)
        }

        private static func testingAllAccounts() -> [String]? {
            inMemoryStoreLock.lock()
            defer { inMemoryStoreLock.unlock() }
            guard let store = inMemoryStoreForTesting else { return nil }
            return Array(store.keys)
        }
    #endif

    @discardableResult
    public static func saveSecret(_ value: String, id: String, agentId: UUID) -> Bool {
        let account = "\(agentId.uuidString).\(id)"
        guard let valueData = value.data(using: .utf8) else { return false }

        #if DEBUG
            let testing = testingSave(value, account: account)
            if testing.enabled {
                return testing.saved
            }
        #endif

        deleteSecret(id: id, agentId: agentId)

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: valueData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    public static func getSecret(id: String, agentId: UUID) -> String? {
        let account = "\(agentId.uuidString).\(id)"

        #if DEBUG
            let testing = testingGet(account: account)
            if testing.enabled {
                return testing.value
            }
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else { return nil }

        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    public static func deleteSecret(id: String, agentId: UUID) -> Bool {
        let account = "\(agentId.uuidString).\(id)"

        #if DEBUG
            let testing = testingDelete(account: account)
            if testing.enabled {
                return testing.deleted
            }
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Enumerates accounts then fetches each value individually.
    public static func getAllSecrets(agentId: UUID) -> [String: String] {
        let prefix = "\(agentId.uuidString)."

        var secrets: [String: String] = [:]
        for account in allAccounts() where account.hasPrefix(prefix) {
            let key = String(account.dropFirst(prefix.count))
            if let value = getSecret(id: key, agentId: agentId) {
                secrets[key] = value
            }
        }
        return secrets
    }

    public static func deleteAllSecrets(agentId: UUID) {
        let prefix = "\(agentId.uuidString)."
        for account in allAccounts() where account.hasPrefix(prefix) {
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: service,
                kSecAttrAccount as String: account,
            ]
            SecItemDelete(query as CFDictionary)
        }
    }

    // MARK: - Environment Safety

    /// Env var names that must never be overridden by user-defined secrets.
    private static let reservedEnvVarNames: Set<String> = [
        "PATH", "HOME", "SHELL", "USER", "LOGNAME",
        "LD_PRELOAD", "LD_LIBRARY_PATH", "DYLD_INSERT_LIBRARIES",
        "VIRTUAL_ENV", "OSAURUS_PLUGIN",
    ]

    /// Returns agent secrets with reserved env var names stripped out.
    static func getFilteredSecrets(agentId: UUID) -> [String: String] {
        getAllSecrets(agentId: agentId).filter { !reservedEnvVarNames.contains($0.key) }
    }

    /// Returns merged agent + plugin secrets with reserved names stripped out.
    /// Plugin secrets override agent secrets of the same name.
    static func mergedSecretsEnvironment(agentId: UUID, pluginId: String) -> [String: String] {
        var env = getFilteredSecrets(agentId: agentId)
        let pluginSecrets =
            ToolSecretsKeychain
            .getAllSecrets(for: pluginId, agentId: agentId)
            .filter { !reservedEnvVarNames.contains($0.key) }
        env.merge(pluginSecrets) { _, new in new }
        return env
    }

    // MARK: - Private

    private static func allAccounts() -> [String] {
        #if DEBUG
            if let accounts = testingAllAccounts() {
                return accounts
            }
        #endif

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
        ]

        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let items = result as? [[String: Any]]
        else { return [] }

        return items.compactMap { $0[kSecAttrAccount as String] as? String }
    }
}
