//
//  MCPProviderKeychain.swift
//  osaurus
//
//  Secure Keychain storage for MCP provider tokens.
//
//  All accounts are scoped under the service `ai.osaurus.mcp` and named
//  `<providerUUID>.<suffix>` so `deleteAllSecrets(for:)` can prefix-match.
//  Suffixes in use:
//    - `.token`               (legacy/static bearer token)
//    - `.oauth.tokens`        (OAuth 2.1 token blob)
//    - `.oauth.client_secret` (OAuth `client_secret` for confidential-client
//                              providers without DCR — e.g. HubSpot)
//    - `.header.<key>`        (per-header secret)
//    - `.env.<key>`           (per-env-var secret for stdio subprocesses)
//

import Foundation

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

    // MARK: - OAuth client_secret
    //
    // Only used by confidential-client OAuth flows that don't ship RFC 7591
    // Dynamic Client Registration (HubSpot's MCP Auth Apps today). Public-
    // native clients leave this slot empty and rely on PKCE alone.

    @discardableResult
    public static func saveOAuthClientSecret(_ clientSecret: String, for providerId: UUID) -> Bool {
        setData(Data(clientSecret.utf8), account: oauthClientSecretAccount(for: providerId))
    }

    public static func getOAuthClientSecret(for providerId: UUID) -> String? {
        getData(account: oauthClientSecretAccount(for: providerId))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    @discardableResult
    public static func deleteOAuthClientSecret(for providerId: UUID) -> Bool {
        deleteItem(account: oauthClientSecretAccount(for: providerId))
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

    /// Delete every Keychain item this enum owns for `providerId` — bearer
    /// token, OAuth tokens, OAuth `client_secret`, and any number of header
    /// or env secrets. Used when removing a provider entirely or resetting
    /// the app.
    public static func deleteAllSecrets(for providerId: UUID) {
        if KeychainQueryHelpers.disablesKeychainForProcess { return }
        // Targeted deletes (cheap, idempotent).
        deleteToken(for: providerId)
        deleteOAuthTokens(for: providerId)
        deleteOAuthClientSecret(for: providerId)

        // Sweep any remaining `<uuid>.header.*` / `<uuid>.env.*` entries.
        let prefix = "\(providerId.uuidString)."
        for account in Keychain.allAccounts(service: service) where account.hasPrefix(prefix) {
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

    private static func oauthClientSecretAccount(for providerId: UUID) -> String {
        "\(providerId.uuidString).oauth.client_secret"
    }

    private static func headerAccount(key: String, for providerId: UUID) -> String {
        "\(providerId.uuidString).header.\(key)"
    }

    private static func envAccount(key: String, for providerId: UUID) -> String {
        "\(providerId.uuidString).env.\(key)"
    }

    // MARK: - Generic CRUD
    //
    // All items route through the shared `Keychain` helper.

    @discardableResult
    private static func setData(_ data: Data, account: String) -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        return Keychain.write(service: service, account: account, data: data)
    }

    private static func getData(account: String) -> Data? {
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        return Keychain.read(service: service, account: account)
    }

    @discardableResult
    private static func deleteItem(account: String) -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
        return Keychain.delete(service: service, account: account)
    }
}
