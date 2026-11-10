//
//  MCPProviderKeychain.swift
//  osaurus
//
//  Keychain storage for MCP server sign-ins, under service `ai.osaurus.mcp`
//  with accounts `<providerUUID>.<suffix>`:
//    - `.oauth.tokens`        (OAuth 2.1 token blob)
//    - `.oauth.client_secret` (OAuth `client_secret` for confidential-client
//                              providers without DCR, e.g. HubSpot)
//  Bearer tokens and secret headers/env vars (`.token`, `.header.<key>`,
//  `.env.<key>`) are read only as the legacy fallback for the Keys store
//  (`MCPCredentials`); they are never written or deleted here.
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

    // MARK: - Legacy bearer token (read-only)

    public static func getToken(for providerId: UUID) -> String? {
        getData(account: tokenAccount(for: providerId)).flatMap { String(data: $0, encoding: .utf8) }
    }

    /// Typed availability of the static bearer token, distinguishing a
    /// definitively missing token from a keychain that can't answer right now.
    public static func tokenAvailability(for providerId: UUID) -> SecretAvailability {
        if _legacyItemsForTesting != nil { return getToken(for: providerId) == nil ? .absent : .present }
        if KeychainQueryHelpers.disablesKeychainForProcess { return .absent }
        return availability(account: tokenAccount(for: providerId)) {
            String(data: $0, encoding: .utf8) != nil
        }
    }

    // MARK: - OAuth tokens

    @discardableResult
    public static func saveOAuthTokens(_ tokens: MCPOAuthTokens, for providerId: UUID) -> Bool {
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return setData(data, account: oauthAccount(for: providerId))
    }

    public static func getOAuthTokens(for providerId: UUID) -> MCPOAuthTokens? {
        guard let data = getData(account: oauthAccount(for: providerId)) else { return nil }
        do {
            return try JSONDecoder().decode(MCPOAuthTokens.self, from: data)
        } catch {
            // Corrupt stored blob, not absence: surface via availability and
            // logs so the caller can offer a re-sign-in instead of silently
            // treating the provider as signed out.
            NSLog("MCPProviderKeychain: stored OAuth token blob failed to decode")
            return nil
        }
    }

    /// Typed availability of the OAuth token blob, distinguishing corrupt
    /// stored data and a transiently unavailable keychain from absence.
    public static func oauthTokensAvailability(for providerId: UUID) -> SecretAvailability {
        if KeychainQueryHelpers.disablesKeychainForProcess { return .absent }
        return availability(account: oauthAccount(for: providerId)) {
            (try? JSONDecoder().decode(MCPOAuthTokens.self, from: $0)) != nil
        }
    }

    @discardableResult
    public static func deleteOAuthTokens(for providerId: UUID) -> Bool {
        deleteItem(account: oauthAccount(for: providerId))
    }

    public static func hasOAuthTokens(for providerId: UUID) -> Bool {
        getOAuthTokens(for: providerId) != nil
    }

    // MARK: - Session OAuth tokens
    //
    // A nil session is the primary one, in the account above. Other
    // sessions keep theirs in `<providerUUID>.session.<sessionUUID>.oauth.tokens`.

    @discardableResult
    public static func saveOAuthTokens(_ tokens: MCPOAuthTokens, for providerId: UUID, session: UUID?) -> Bool {
        guard let session else { return saveOAuthTokens(tokens, for: providerId) }
        guard let data = try? JSONEncoder().encode(tokens) else { return false }
        return SessionKeychainItems.write(
            service: service, account: SessionKeychainItems.account(providerId, session: session, suffix: "oauth.tokens"),
            data: data)
    }

    public static func getOAuthTokens(for providerId: UUID, session: UUID?) -> MCPOAuthTokens? {
        guard let session else { return getOAuthTokens(for: providerId) }
        let account = SessionKeychainItems.account(providerId, session: session, suffix: "oauth.tokens")
        return SessionKeychainItems.read(service: service, account: account)
            .flatMap { try? JSONDecoder().decode(MCPOAuthTokens.self, from: $0) }
    }

    public static func oauthTokensAvailability(for providerId: UUID, session: UUID?) -> SecretAvailability {
        guard let session else { return oauthTokensAvailability(for: providerId) }
        return SessionKeychainItems.availability(
            service: service, account: SessionKeychainItems.account(providerId, session: session, suffix: "oauth.tokens")
        ) { (try? JSONDecoder().decode(MCPOAuthTokens.self, from: $0)) != nil }
    }

    @discardableResult
    public static func deleteOAuthTokens(for providerId: UUID, session: UUID?) -> Bool {
        guard let session else { return deleteOAuthTokens(for: providerId) }
        return SessionKeychainItems.delete(
            service: service, account: SessionKeychainItems.account(providerId, session: session, suffix: "oauth.tokens"))
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

    // MARK: - Legacy header and env secrets (read-only)

    public static func getHeaderSecret(key: String, for providerId: UUID) -> String? {
        getData(account: headerAccount(key: key, for: providerId))
            .flatMap { String(data: $0, encoding: .utf8) }
    }

    public static func getEnvSecret(key: String, for providerId: UUID) -> String? {
        getData(account: envAccount(key: key, for: providerId))
            .flatMap { String(data: $0, encoding: .utf8) }
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

    /// Map the typed read outcome for `account` into a `SecretAvailability`,
    /// using `decodes` to detect a corrupt payload.
    private static func availability(
        account: String, decodes: (Data) -> Bool
    ) -> SecretAvailability {
        switch Keychain.readItem(service: service, account: account) {
        case .found(let data):
            return decodes(data) ? .present : .corrupt
        case .notFound, .disabled:
            return .absent
        case .unavailable, .accessDenied, .failure:
            return .unavailable
        }
    }

    @discardableResult
    private static func setData(_ data: Data, account: String) -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return false }
        return Keychain.write(service: service, account: account, data: data)
    }

    /// Tests: legacy items by account, read instead of the Keychain.
    @TaskLocal static var _legacyItemsForTesting: [String: String]?

    private static func getData(account: String) -> Data? {
        if let items = _legacyItemsForTesting { return items[account].map { Data($0.utf8) } }
        if KeychainQueryHelpers.disablesKeychainForProcess { return nil }
        return Keychain.read(service: service, account: account)
    }

    @discardableResult
    private static func deleteItem(account: String) -> Bool {
        if KeychainQueryHelpers.disablesKeychainForProcess { return true }
        return Keychain.delete(service: service, account: account)
    }
}
