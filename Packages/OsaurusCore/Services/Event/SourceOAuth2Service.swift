//
//  SourceOAuth2Service.swift
//  osaurus
//
//  OAuth 2 sign-in for source connections whose type authenticates with
//  `.oauth2(profile)`: authorization code + PKCE through a loopback
//  redirect, tokens in `SourceCredentialVault`, refresh on demand. Built on
//  the same PKCE, loopback and token-request pieces as `MCPOAuthService`;
//  a provider is a `SourceOAuth2ProviderProfile`, not a new code path.
//

import AppKit
import Foundation

public enum SourceOAuth2Error: LocalizedError, Sendable, Equatable {
    case browserOpenFailed
    case notSignedIn
    case noRefreshToken

    public var errorDescription: String? {
        switch self {
        case .browserOpenFailed: L("Could not open the browser to sign in.")
        case .notSignedIn: L("This account is not signed in. Sign in again.")
        case .noRefreshToken: L("The sign-in expired and cannot be renewed. Sign in again.")
        }
    }
}

@MainActor
public enum SourceOAuth2Service {
    /// Seconds before expiry at which `validAccessToken` refreshes.
    static let refreshLeeway: TimeInterval = 120

    /// Runs the browser sign-in and stores the tokens for `connectionId`.
    @discardableResult
    public static func signIn(
        profile: SourceOAuth2ProviderProfile, connectionId: String
    ) async throws -> MCPOAuthTokens {
        let pkce = try PKCE.makePair()
        let state = PKCE.makeState()
        let server = try OAuthLoopbackServer(expectedState: state, port: .ephemeral, callbackPath: "/callback")
        try await server.start()
        defer { server.stop() }
        guard let port = server.boundPort, port != 0 else {
            throw OAuthLoopbackError.bindFailed("listener never reported a port")
        }
        let redirectURI = "http://127.0.0.1:\(port)/callback"
        let url = authorizationURL(profile: profile, redirectURI: redirectURI, pkce: pkce, state: state)
        guard await NSWorkspace.shared.openAsync(url) else { throw SourceOAuth2Error.browserOpenFailed }
        let callback = try await server.waitForCallback(timeout: MCPOAuthService.signInCallbackTimeout)
        let tokens = try await MCPOAuthService.exchangeAuthorizationCode(
            tokenURL: profile.tokenEndpoint, clientId: profile.clientId, code: callback.code,
            verifier: pkce.verifier, redirectURI: redirectURI, resource: nil)
        store(tokens, connectionId: connectionId)
        return tokens
    }

    static func authorizationURL(
        profile: SourceOAuth2ProviderProfile, redirectURI: String, pkce: PKCEPair, state: String
    ) -> URL {
        let base = MCPOAuthService.authorizationURL(
            authorizationEndpoint: profile.authorizationEndpoint, clientId: profile.clientId,
            redirectURI: redirectURI, codeChallenge: pkce.challenge, state: state, scopes: profile.scopes,
            resource: nil)
        guard !profile.extraAuthorizationParameters.isEmpty,
            var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { return base }
        var items = components.queryItems ?? []
        for (name, value) in profile.extraAuthorizationParameters.sorted(by: { $0.key < $1.key }) {
            items.append(URLQueryItem(name: name, value: value))
        }
        components.queryItems = items
        return components.url ?? base
    }

    /// A non-expired access token, refreshing first when it is about to
    /// expire.
    public static func validAccessToken(
        profile: SourceOAuth2ProviderProfile, connectionId: String, now: Date = Date()
    ) async throws -> String {
        guard let tokens = tokens(connectionId: connectionId) else { throw SourceOAuth2Error.notSignedIn }
        if tokens.expiresAt.timeIntervalSince(now) > refreshLeeway { return tokens.accessToken }
        return try await refresh(profile: profile, connectionId: connectionId, tokens: tokens).accessToken
    }

    static func refresh(
        profile: SourceOAuth2ProviderProfile, connectionId: String, tokens: MCPOAuthTokens
    ) async throws -> MCPOAuthTokens {
        guard let refreshToken = tokens.refreshToken, !refreshToken.isEmpty else {
            throw SourceOAuth2Error.noRefreshToken
        }
        let parsed = try await MCPOAuthService.postTokenRequest(
            url: profile.tokenEndpoint,
            form: ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": profile.clientId])
        let refreshed = MCPOAuthTokens(
            accessToken: parsed.accessToken,
            // Providers that do not rotate refresh tokens omit it.
            refreshToken: parsed.refreshToken ?? refreshToken,
            expiresAt: parsed.expiresAt,
            scope: parsed.scope ?? tokens.scope)
        store(refreshed, connectionId: connectionId)
        return refreshed
    }

    public static func tokens(connectionId: String) -> MCPOAuthTokens? {
        guard let raw = SourceCredentialVault.read(connectionId: connectionId, field: SourceCredentialVault.oauthTokensField)
        else { return nil }
        return try? EventStore.decoder.decode(MCPOAuthTokens.self, from: Data(raw.utf8))
    }

    static func store(_ tokens: MCPOAuthTokens, connectionId: String) {
        guard let data = try? EventStore.encoder.encode(tokens) else { return }
        SourceCredentialVault.save(
            String(decoding: data, as: UTF8.self), connectionId: connectionId,
            field: SourceCredentialVault.oauthTokensField)
    }

    public static func signOut(connectionId: String) {
        SourceCredentialVault.delete(connectionId: connectionId, field: SourceCredentialVault.oauthTokensField)
    }
}
