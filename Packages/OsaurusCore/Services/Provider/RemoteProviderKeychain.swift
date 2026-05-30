//
//  RemoteProviderKeychain.swift
//  osaurus
//
//  Secure Keychain storage for remote OpenAI-compatible provider credentials.
//

import Foundation

public struct RemoteProviderOAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date
    public var accountId: String

    public init(accessToken: String, refreshToken: String, expiresAt: Date, accountId: String) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.accountId = accountId
    }

    public var isExpired: Bool {
        expiresAt <= Date().addingTimeInterval(60)
    }
}

/// Keychain wrapper for secure remote provider credential storage
public enum RemoteProviderKeychain {
    private static let service = "ai.osaurus.remote"

    public static func runOffCooperativeExecutor<T: Sendable>(
        _ operation: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: operation())
            }
        }
    }

    // MARK: - API Key Management

    /// Save an API key for a provider ID
    @discardableResult
    public static func saveAPIKey(_ apiKey: String, for providerId: UUID) -> Bool {
        guard let keyData = apiKey.data(using: .utf8) else { return false }
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        return setData(keyData, account: apiKeyAccount(for: providerId))
    }

    /// Retrieve an API key for a provider ID
    public static func getAPIKey(for providerId: UUID) -> String? {
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        return getData(account: apiKeyAccount(for: providerId)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Delete an API key for a provider ID
    @discardableResult
    public static func deleteAPIKey(for providerId: UUID) -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
        return deleteItem(account: apiKeyAccount(for: providerId))
    }

    /// Check if an API key exists for a provider ID
    public static func hasAPIKey(for providerId: UUID) -> Bool {
        return getAPIKey(for: providerId) != nil
    }

    // MARK: - OAuth Token Management

    @discardableResult
    public static func saveOAuthTokens(_ tokens: RemoteProviderOAuthTokens, for providerId: UUID) -> Bool {
        guard let tokenData = try? JSONEncoder().encode(tokens) else { return false }
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        return setData(tokenData, account: oauthAccount(for: providerId))
    }

    @discardableResult
    public static func saveOAuthTokensOffMainActor(_ tokens: RemoteProviderOAuthTokens, for providerId: UUID) async
        -> Bool
    {
        await runOffCooperativeExecutor {
            saveOAuthTokens(tokens, for: providerId)
        }
    }

    public static func getOAuthTokens(for providerId: UUID) -> RemoteProviderOAuthTokens? {
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        return getData(account: oauthAccount(for: providerId))
            .flatMap { try? JSONDecoder().decode(RemoteProviderOAuthTokens.self, from: $0) }
    }

    @discardableResult
    public static func deleteOAuthTokens(for providerId: UUID) -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
        return deleteItem(account: oauthAccount(for: providerId))
    }

    public static func hasOAuthTokens(for providerId: UUID) -> Bool {
        getOAuthTokens(for: providerId) != nil
    }

    // MARK: - Header Secret Management

    /// Save a secret header value for a provider
    @discardableResult
    public static func saveHeaderSecret(_ value: String, key: String, for providerId: UUID) -> Bool {
        guard let valueData = value.data(using: .utf8) else { return false }
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        return setData(valueData, account: headerAccount(key: key, for: providerId))
    }

    /// Retrieve a secret header value for a provider
    public static func getHeaderSecret(key: String, for providerId: UUID) -> String? {
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        return getData(account: headerAccount(key: key, for: providerId)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Delete a secret header value for a provider
    @discardableResult
    public static func deleteHeaderSecret(key: String, for providerId: UUID) -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
        return deleteItem(account: headerAccount(key: key, for: providerId))
    }

    /// Delete all secrets for a provider (API key + all header secrets)
    public static func deleteAllSecrets(for providerId: UUID) {
        if KeychainQueryHelpers.disablesKeychainForProcess { return }
        deleteAPIKey(for: providerId)
        deleteOAuthTokens(for: providerId)

        // Sweep any remaining `<uuid>.*` accounts (header secrets).
        let accountPrefix = "\(providerId.uuidString)."
        for account in allAccounts() where account.hasPrefix(accountPrefix) {
            deleteItem(account: account)
        }
    }

    // MARK: - Account naming

    private static func apiKeyAccount(for providerId: UUID) -> String {
        "\(providerId.uuidString).apiKey"
    }

    private static func oauthAccount(for providerId: UUID) -> String {
        "\(providerId.uuidString).oauth.tokens"
    }

    private static func headerAccount(key: String, for providerId: UUID) -> String {
        "\(providerId.uuidString).header.\(key)"
    }

    // MARK: - Generic CRUD
    //
    // All items route through the shared `Keychain` helper.

    @discardableResult
    private static func setData(_ data: Data, account: String) -> Bool {
        Keychain.write(service: service, account: account, data: data)
    }

    private static func getData(account: String) -> Data? {
        Keychain.read(service: service, account: account)
    }

    @discardableResult
    private static func deleteItem(account: String) -> Bool {
        Keychain.delete(service: service, account: account)
    }

    private static func allAccounts() -> [String] {
        Keychain.allAccounts(service: service)
    }
}
