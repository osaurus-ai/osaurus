//
//  MCPProviderKeychain.swift
//  osaurus
//
//  Secure Keychain storage for MCP provider tokens.
//
//  All accounts are scoped under the service `ai.osaurus.mcp` and named
//  `<providerUUID>.<suffix>` so `deleteAllSecrets(for:)` can prefix-match.
//  Suffixes in use:
//    - `.token`         (legacy/static bearer token)
//    - `.oauth.tokens`  (OAuth 2.1 token blob)
//    - `.header.<key>`  (per-header secret)
//    - `.env.<key>`     (per-env-var secret for stdio subprocesses)
//

import Foundation
import Security

/// OAuth 2.1 tokens for a remote MCP provider (per the MCP authorization spec).
///
/// Stored as a single JSON blob in Keychain so access/refresh/scope/expiry stay atomic.
/// The 60s skew on `isExpired` matches `RemoteProviderOAuthTokens` so refresh fires
/// before the server starts handing out 401s.
public struct MCPOAuthTokens: Codable, Sendable, Equatable {
    public var accessToken: String
    /// Some servers (e.g. very short-lived sessions) omit refresh_token entirely;
    /// in that case the user must re-sign-in when `accessToken` expires.
    public var refreshToken: String?
    public var expiresAt: Date
    /// Space-delimited scopes the server actually granted (may differ from requested).
    public var scope: String?

    public init(accessToken: String, refreshToken: String?, expiresAt: Date, scope: String?) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    public var isExpired: Bool {
        expiresAt <= Date().addingTimeInterval(60)
    }
}

/// Keychain wrapper for secure MCP provider token storage.
public enum MCPProviderKeychain {
    private static let service = "ai.osaurus.mcp"

    // MARK: - Static token (legacy / explicit bearer)

    @discardableResult
    public static func saveToken(_ token: String, for providerId: UUID) -> Bool {
        setData(Data(token.utf8), account: tokenAccount(for: providerId))
    }

    public static func getToken(for providerId: UUID) -> String? {
        getData(account: tokenAccount(for: providerId)).flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    public static func deleteToken(for providerId: UUID) -> Bool {
        deleteItem(account: tokenAccount(for: providerId))
    }

    public static func hasToken(for providerId: UUID) -> Bool {
        getToken(for: providerId) != nil
    }

    // MARK: - OAuth tokens

    @discardableResult
    public static func saveOAuthTokens(_ tokens: MCPOAuthTokens, for providerId: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return setData(data, account: oauthAccount(for: providerId))
    }

    public static func getOAuthTokens(for providerId: UUID) -> MCPOAuthTokens? {
        getData(account: oauthAccount(for: providerId))
            .flatMap { try? JSONDecoder().decode(MCPOAuthTokens.self, from: $0) }
    }

    @discardableResult
    public static func deleteOAuthTokens(for providerId: UUID) -> Bool {
        deleteItem(account: oauthAccount(for: providerId))
    }

    public static func hasOAuthTokens(for providerId: UUID) -> Bool {
        getOAuthTokens(for: providerId) != nil
    }

    // MARK: - Header secrets

    @discardableResult
    public static func saveHeaderSecret(_ value: String, key: String, for providerId: UUID) -> Bool {
        setData(Data(value.utf8), account: headerAccount(key: key, for: providerId))
    }

    public static func getHeaderSecret(key: String, for providerId: UUID) -> String? {
        getData(account: headerAccount(key: key, for: providerId))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    public static func deleteHeaderSecret(key: String, for providerId: UUID) -> Bool {
        deleteItem(account: headerAccount(key: key, for: providerId))
    }

    // MARK: - Env secrets (stdio subprocess)

    @discardableResult
    public static func saveEnvSecret(_ value: String, key: String, for providerId: UUID) -> Bool {
        setData(Data(value.utf8), account: envAccount(key: key, for: providerId))
    }

    public static func getEnvSecret(key: String, for providerId: UUID) -> String? {
        getData(account: envAccount(key: key, for: providerId))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    public static func deleteEnvSecret(key: String, for providerId: UUID) -> Bool {
        deleteItem(account: envAccount(key: key, for: providerId))
    }

    // MARK: - Bulk delete

    /// Delete every Keychain item this enum owns for `providerId` — token, OAuth blob,
    /// and any number of header secrets. Used when removing a provider entirely or
    /// resetting the app.
    public static func deleteAllSecrets(for providerId: UUID) {
        if KeychainQueryHelpers.disablesKeychainForProcess { return }
        // Targeted deletes (cheap, idempotent).
        deleteToken(for: providerId)
        deleteOAuthTokens(for: providerId)

        // Sweep any remaining `<uuid>.header.*` entries by enumerating accounts.
        let prefix = "\(providerId.uuidString)."
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitAll,
            kSecReturnAttributes as String: true,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext(),
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let items = result as? [[String: Any]]
        else { return }

        for item in items {
            guard let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(prefix)
            else { continue }
            deleteItem(account: account)
        }
    }

    // MARK: - Account naming

    private static func tokenAccount(for providerId: UUID) -> String {
        "\(providerId.uuidString).token"
    }

    private static func oauthAccount(for providerId: UUID) -> String {
        "\(providerId.uuidString).oauth.tokens"
    }

    private static func headerAccount(key: String, for providerId: UUID) -> String {
        "\(providerId.uuidString).header.\(key)"
    }

    private static func envAccount(key: String, for providerId: UUID) -> String {
        "\(providerId.uuidString).env.\(key)"
    }

    // MARK: - Generic CRUD

    /// Upsert `data` for `account`. Always deletes any existing item first so callers
    /// don't have to worry about the difference between `SecItemAdd` and `SecItemUpdate`.
    @discardableResult
    private static func setData(_ data: Data, account: String) -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        deleteItem(account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
        ]
        return SecItemAdd(query as CFDictionary, nil) == errSecSuccess
    }

    private static func getData(account: String) -> Data? {
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseAuthenticationUI as String: kSecUseAuthenticationUISkip,
            kSecUseAuthenticationContext as String: KeychainQueryHelpers.nonInteractiveContext(),
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    @discardableResult
    private static func deleteItem(account: String) -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }
}
