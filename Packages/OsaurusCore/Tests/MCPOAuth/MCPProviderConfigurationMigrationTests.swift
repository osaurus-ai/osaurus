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
        // Public-native (DCR) clients leave the loopback port unspecified.
        // Confirm the default doesn't accidentally get promoted to a fixed
        // port — that would break the ephemeral-port redirect URI vendors
        // like Linear / Notion expect.
        #expect(decoded.oauth?.loopbackPort == nil)
    }

    @Test func newJSONRoundTripsConfidentialOAuthLoopbackPort() throws {
        // HubSpot's MCP Auth Apps require an exact-match redirect URI, so
        // the loopback port is pinned in the saved provider record. Make
        // sure the field round-trips so a refresh after a relaunch keeps
        // binding the same port the user registered with HubSpot.
        let provider = MCPProvider(
            id: UUID(),
            name: "HubSpot",
            url: "https://mcp.hubspot.com",
            authType: .oauth,
            oauth: MCPOAuthConfig(
                clientId: "client_abc",
                redirectURI: "http://127.0.0.1:33267/callback",
                tokenEndpoint: "https://mcp.hubspot.com/oauth/v3/token",
                loopbackPort: 33267
            )
        )
        let encoded = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(MCPProvider.self, from: encoded)
        #expect(decoded.oauth?.loopbackPort == 33267)
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

    /// Records written before the stdio fields existed should decode with
    /// safe defaults (`.http` + `.sandbox`) and no command/args/env. Without
    /// this the launch path would crash on any pre-existing config.
    @Test func legacyJSONDefaultsToHTTPTransport() throws {
        let legacyJSON = """
            {
              "id": "22222222-2222-2222-2222-222222222222",
              "name": "Legacy",
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
        #expect(provider.transport == .http)
        #expect(provider.executionHost == .sandbox)
        #expect(provider.command == "")
        #expect(provider.args.isEmpty)
        #expect(provider.env.isEmpty)
        #expect(provider.secretEnvKeys.isEmpty)
        #expect(provider.workingDirectory == nil)
    }

    @Test func stdioProviderRoundTrips() throws {
        let provider = MCPProvider(
            name: "Local FS",
            url: "",
            authType: .none,
            transport: .stdio,
            executionHost: .sandbox,
            command: "/usr/local/bin/uvx",
            args: ["mcp-fs", "--root", "/tmp"],
            env: ["LOG_LEVEL": "debug"],
            secretEnvKeys: ["API_KEY"],
            workingDirectory: "/tmp"
        )
        let encoded = try JSONEncoder().encode(provider)
        let decoded = try JSONDecoder().decode(MCPProvider.self, from: encoded)
        #expect(decoded.transport == .stdio)
        #expect(decoded.executionHost == .sandbox)
        #expect(decoded.command == "/usr/local/bin/uvx")
        #expect(decoded.args == ["mcp-fs", "--root", "/tmp"])
        #expect(decoded.env["LOG_LEVEL"] == "debug")
        #expect(decoded.secretEnvKeys == ["API_KEY"])
        #expect(decoded.workingDirectory == "/tmp")
    }
}
