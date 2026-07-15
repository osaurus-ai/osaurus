//
//  SearchProviderKeychain.swift
//  osaurus
//
//  Secure Keychain storage for search-provider API keys.
//
//  All accounts are scoped under the service `ai.osaurus.search` and named
//  `<definitionId>.<fieldId>` so `deleteAllSecrets(for:)` can prefix-match.
//

import Foundation

public enum SearchProviderKeychain {
    private static let service = "ai.osaurus.search"

    @discardableResult
    public static func saveSecret(_ value: String, field: String, for definitionId: String) -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        return Keychain.write(
            service: service,
            account: account(field: field, for: definitionId),
            data: Data(value.utf8)
        )
    }

    public static func getSecret(field: String, for definitionId: String) -> String? {
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        return Keychain.read(service: service, account: account(field: field, for: definitionId))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    public static func deleteSecret(field: String, for definitionId: String) -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
        return Keychain.delete(service: service, account: account(field: field, for: definitionId))
    }

    /// Delete every Keychain item owned for `definitionId`. Used when the
    /// user removes a provider entirely.
    public static func deleteAllSecrets(for definitionId: String) {
        if KeychainQueryHelpers.disablesKeychainForProcess { return }
        let prefix = "\(definitionId)."
        for account in Keychain.allAccounts(service: service) where account.hasPrefix(prefix) {
            _ = Keychain.delete(service: service, account: account)
        }
    }

    private static func account(field: String, for definitionId: String) -> String {
        "\(definitionId).\(field)"
    }
}
