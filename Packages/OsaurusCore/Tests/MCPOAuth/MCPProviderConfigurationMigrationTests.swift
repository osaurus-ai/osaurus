//
//  MCPProviderConfigurationMigrationTests.swift
//  osaurusTests
//
//  Backward compatibility for existing `mcp.json` files that pre-date the
//  authType / oauth fields. Decoder must default authType to .bearerToken
//  so users upgrading don't lose their existing static-token providers.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("MCPProvider migration")
struct MCPProviderConfigurationMigrationTests {
    @Test func legacyJSONDecodesAsBearerToken() throws {
        let legacyJSON = """
            {
              "id": "11111111-1111-1111-1111-111111111111",
              "name": "Legacy Server",
              "url": "https://mcp.example.com",
              "enabled": true,
              "customHeaders": {},
              "streamingEnabled": false,
              "discoveryTimeout": 20,
              "toolCallTimeout": 45,
              "autoConnect": true,
              "secretHeaderKeys": []
            }
            """
        let provider = try JSONDecoder().decode(MCPProvider.self, from: Data(legacyJSON.utf8))
        #expect(provider.authType == .bearerToken)
        #expect(provider.oauth == nil)
        #expect(provider.name == "Legacy Server")
        #expect(provider.url == "https://mcp.example.com")
    }

    @Test func newJSONRoundTripsOAuth() throws {
        let provider = MCPProvider(
            id: UUID(),
            name: "Linear",
            url: "https://mcp.linear.app/mcp",
            authType: .oauth,
            oauth: MCPOAuthConfig(
                clientId: "client_abc",
                redirectURI: "http://127.0.0.1:54321/callback",
                scopes: ["read", "write"],
                resource: "https://mcp.linear.app/mcp",
                issuer: "https://mcp.linear.app",
                authorizationEndpoint: "https://mcp.linear.app/oauth/authorize",
                tokenEndpoint: "https://mcp.linear.app/oauth/token",
                registrationEndpoint: "https://mcp.linear.app/oauth/register"
            )
        )
        let encoded = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(MCPProvider.self, from: encoded)
        #expect(decoded.authType == .oauth)
        #expect(decoded.oauth?.clientId == "client_abc")
        #expect(decoded.oauth?.scopes == ["read", "write"])
        #expect(decoded.oauth?.resource == "https://mcp.linear.app/mcp")
    }

    @Test func oauthTokensDoNotPersistInJSON() throws {
        // Tokens live in Keychain only; the provider record never carries them.
        let provider = MCPProvider(
            id: UUID(),
            name: "x",
            url: "https://x",
            authType: .oauth,
            oauth: MCPOAuthConfig(clientId: "abc")
        )
        let encoded = try JSONEncoder().encode(provider)
        let json = String(data: encoded, encoding: .utf8) ?? ""
        #expect(!json.contains("accessToken"))
        #expect(!json.contains("refreshToken"))
    }

    @Test func tokenSkewMakesFreshTokensNotExpired() {
        let tokens = MCPOAuthTokens(
            accessToken: "AT",
            refreshToken: "RT",
            expiresAt: Date().addingTimeInterval(3600),
            scope: nil
        )
        #expect(!tokens.isExpired)
    }

    @Test func tokenSkewMakesNearExpiryTokensExpired() {
        // 60s skew — a 30s-from-now token should already count as expired.
        let tokens = MCPOAuthTokens(
            accessToken: "AT",
            refreshToken: "RT",
            expiresAt: Date().addingTimeInterval(30),
            scope: nil
        )
        #expect(tokens.isExpired)
    }
}
