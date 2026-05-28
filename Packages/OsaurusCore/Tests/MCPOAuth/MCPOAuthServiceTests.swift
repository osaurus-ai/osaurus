//
//  MCPOAuthServiceTests.swift
//  osaurusTests
//
//  Pure helpers for the MCP OAuth orchestration service:
//    - authorizationURL parameter shape (PKCE + state + resource indicator)
//    - scope resolution precedence
//    - token-response parsing (with/without expires_in, with/without refresh_token)
//    - refresh-token rotation behavior
//

import Foundation
import Testing

@testable import OsaurusCore

// `tokenRequestOverride` and `clientSecretAccessorOverride` are global test
// seams; running tests in this suite in parallel would let one test's
// captured form get clobbered by another's. `.serialized` keeps the
// previously-passing fixture-based tests deterministic alongside the new
// confidential-client tests added below.
@Suite("MCP OAuth service helpers", .serialized)
struct MCPOAuthServiceTests {
    @Test func authorizationURLContainsRequiredParameters() {
        let url = MCPOAuthService.authorizationURL(
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            clientId: "client_abc",
            redirectURI: "http://127.0.0.1:54321/callback",
            codeChallenge: "challenge",
            state: "state-hex",
            scopes: ["openid", "offline_access"],
            resource: "https://mcp.example.com/mcp"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(params["response_type"] == "code")
        #expect(params["client_id"] == "client_abc")
        #expect(params["redirect_uri"] == "http://127.0.0.1:54321/callback")
        #expect(params["code_challenge"] == "challenge")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["state"] == "state-hex")
        #expect(params["scope"] == "openid offline_access")
        // RFC 8707 — must be present on every authorize request.
        #expect(params["resource"] == "https://mcp.example.com/mcp")
    }

    @Test func authorizationURLOmitsResourceWhenNil() {
        let url = MCPOAuthService.authorizationURL(
            authorizationEndpoint: URL(string: "https://auth.example.com/authorize")!,
            clientId: "c",
            redirectURI: "http://127.0.0.1:1/callback",
            codeChallenge: "c",
            state: "s",
            scopes: [],
            resource: nil
        )
        let params = (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { $0.name }
        #expect(!params.contains("resource"))
        #expect(!params.contains("scope"))
    }

    @Test func parseTokenResponseHandlesFullPayload() throws {
        let json = """
            {
              "access_token": "AT",
              "refresh_token": "RT",
              "expires_in": 3600,
              "scope": "read write"
            }
            """
        let parsed = try MCPOAuthService.parseTokenResponse(Data(json.utf8))
        #expect(parsed.accessToken == "AT")
        #expect(parsed.refreshToken == "RT")
        #expect(parsed.scope == "read write")
        // 3600s ahead of "now", with sub-second timing slack.
        #expect(abs(parsed.expiresAt.timeIntervalSinceNow - 3600) < 5)
    }

    @Test func parseTokenResponseDefaultsExpiry() throws {
        // Some servers omit expires_in. We must still pick a sensible default so the
        // refresh-before-connect path eventually fires.
        let json = #"{"access_token":"AT","refresh_token":"RT"}"#
        let parsed = try MCPOAuthService.parseTokenResponse(Data(json.utf8))
        #expect(parsed.accessToken == "AT")
        #expect(parsed.refreshToken == "RT")
        #expect(parsed.expiresAt > Date().addingTimeInterval(60))
    }

    @Test func parseTokenResponseRejectsMissingAccessToken() {
        #expect(throws: MCPOAuthError.self) {
            _ = try MCPOAuthService.parseTokenResponse(Data(#"{"refresh_token":"x"}"#.utf8))
        }
    }

    @Test func resolveScopesPrefersHintOverEverything() {
        let provider = MCPProvider(name: "p", url: "https://x", authType: .oauth)
        let prm = makePRM(scopes: ["prm-scope"])
        let asm = makeASM(scopes: ["asm-scope"])
        let hint = MCPBearerChallenge(scope: "hint-a hint-b")

        let resolved = MCPOAuthService.resolveScopes(provider: provider, prm: prm, asm: asm, hint: hint)
        #expect(resolved == ["hint-a", "hint-b"])
    }

    @Test func resolveScopesFallsBackToProviderThenPRMThenASMThenDefault() {
        let prm = makePRM(scopes: ["prm-only"])
        let asm = makeASM(scopes: ["asm-only"])

        let withSaved = MCPProvider(
            name: "p",
            url: "https://x",
            authType: .oauth,
            oauth: MCPOAuthConfig(scopes: ["saved"])
        )
        #expect(MCPOAuthService.resolveScopes(provider: withSaved, prm: prm, asm: asm, hint: nil) == ["saved"])

        let withPRM = MCPProvider(name: "p", url: "https://x", authType: .oauth)
        #expect(MCPOAuthService.resolveScopes(provider: withPRM, prm: prm, asm: asm, hint: nil) == ["prm-only"])

        let withASMOnly = MCPProvider(name: "p", url: "https://x", authType: .oauth)
        let asmOnlyPRM = makePRM(scopes: nil)
        #expect(
            MCPOAuthService.resolveScopes(provider: withASMOnly, prm: asmOnlyPRM, asm: asm, hint: nil) == ["asm-only"]
        )

        let bare = MCPProvider(name: "p", url: "https://x", authType: .oauth)
        let emptyPRM = makePRM(scopes: nil)
        let emptyASM = makeASM(scopes: nil)
        #expect(
            MCPOAuthService.resolveScopes(provider: bare, prm: emptyPRM, asm: emptyASM, hint: nil)
                == MCPOAuthService.defaultScopes
        )
    }

    @Test func refreshTokenRotationKeepsExistingRefreshTokenWhenServerOmitsIt() async throws {
        var capturedForm: [String: String]?
        MCPOAuthService.tokenRequestOverride = { _, form in
            capturedForm = form
            // Simulate Notion-style omission of refresh_token on rotation.
            return MCPOAuthService.ParsedTokenResponse(
                accessToken: "AT2",
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(3600),
                scope: "read"
            )
        }
        defer { MCPOAuthService.tokenRequestOverride = nil }

        let provider = MCPProvider(
            name: "p",
            url: "https://mcp.example.com/mcp",
            authType: .oauth,
            oauth: MCPOAuthConfig(
                clientId: "client_abc",
                scopes: ["read"],
                resource: "https://mcp.example.com/mcp",
                tokenEndpoint: "https://auth.example.com/token"
            )
        )
        let original = MCPOAuthTokens(
            accessToken: "AT1",
            refreshToken: "RT1",
            expiresAt: Date().addingTimeInterval(-10),
            scope: "read"
        )

        let refreshed = try await MCPOAuthService.refresh(provider: provider, tokens: original, persist: false)
        #expect(refreshed.accessToken == "AT2")
        // RFC 6749 §6: when the server omits a new refresh_token, keep the old one.
        #expect(refreshed.refreshToken == "RT1")
        // The form must include grant_type=refresh_token + client_id + resource.
        #expect(capturedForm?["grant_type"] == "refresh_token")
        #expect(capturedForm?["client_id"] == "client_abc")
        #expect(capturedForm?["refresh_token"] == "RT1")
        #expect(capturedForm?["resource"] == "https://mcp.example.com/mcp")
    }

    @Test func refreshFailsWhenNoRefreshTokenSaved() async {
        let provider = MCPProvider(
            name: "p",
            url: "https://mcp.example.com/mcp",
            authType: .oauth,
            oauth: MCPOAuthConfig(
                clientId: "client_abc",
                tokenEndpoint: "https://auth.example.com/token"
            )
        )
        let tokens = MCPOAuthTokens(
            accessToken: "AT",
            refreshToken: nil,
            expiresAt: Date(),
            scope: nil
        )
        await #expect(throws: MCPOAuthError.self) {
            _ = try await MCPOAuthService.refresh(provider: provider, tokens: tokens, persist: false)
        }
    }

    // MARK: - Confidential-client (`client_secret_post`) support
    //
    // Vendors whose ASM advertises `client_secret_post` (HubSpot's MCP Auth
    // Apps) need `client_secret` in every token-endpoint POST. Public-native
    // clients (Linear, Notion, etc.) leave the slot empty and rely on PKCE
    // alone. These tests pin both paths so a future refactor can't silently
    // drop the secret.

    @Test func exchangeAuthorizationCodeIncludesClientSecretWhenProvided() async throws {
        var capturedForm: [String: String]?
        MCPOAuthService.tokenRequestOverride = { _, form in
            capturedForm = form
            return MCPOAuthService.ParsedTokenResponse(
                accessToken: "AT",
                refreshToken: "RT",
                expiresAt: Date().addingTimeInterval(3600),
                scope: nil
            )
        }
        defer { MCPOAuthService.tokenRequestOverride = nil }

        _ = try await MCPOAuthService.exchangeAuthorizationCode(
            tokenURL: URL(string: "https://auth.example.com/token")!,
            clientId: "client_abc",
            clientSecret: "secret-xyz",
            code: "auth-code",
            verifier: "verifier-abc",
            redirectURI: "http://127.0.0.1:33267/callback",
            resource: "https://mcp.example.com"
        )

        #expect(capturedForm?["grant_type"] == "authorization_code")
        #expect(capturedForm?["client_id"] == "client_abc")
        #expect(capturedForm?["client_secret"] == "secret-xyz")
        #expect(capturedForm?["code_verifier"] == "verifier-abc")
        #expect(capturedForm?["redirect_uri"] == "http://127.0.0.1:33267/callback")
    }

    @Test func exchangeAuthorizationCodeOmitsClientSecretWhenNil() async throws {
        var capturedForm: [String: String]?
        MCPOAuthService.tokenRequestOverride = { _, form in
            capturedForm = form
            return MCPOAuthService.ParsedTokenResponse(
                accessToken: "AT",
                refreshToken: nil,
                expiresAt: Date().addingTimeInterval(3600),
                scope: nil
            )
        }
        defer { MCPOAuthService.tokenRequestOverride = nil }

        _ = try await MCPOAuthService.exchangeAuthorizationCode(
            tokenURL: URL(string: "https://auth.example.com/token")!,
            clientId: "client_abc",
            code: "auth-code",
            verifier: "verifier-abc",
            redirectURI: "http://127.0.0.1:1/callback",
            resource: nil
        )

        #expect(capturedForm?["client_id"] == "client_abc")
        #expect(capturedForm?["client_secret"] == nil)
    }

    @Test func refreshIncludesClientSecretFromKeychainAccessor() async throws {
        let providerId = UUID()
        var capturedForm: [String: String]?
        MCPOAuthService.tokenRequestOverride = { _, form in
            capturedForm = form
            return MCPOAuthService.ParsedTokenResponse(
                accessToken: "AT2",
                refreshToken: "RT2",
                expiresAt: Date().addingTimeInterval(3600),
                scope: nil
            )
        }
        MCPOAuthService.clientSecretAccessorOverride = { id in
            id == providerId ? "secret-xyz" : nil
        }
        defer {
            MCPOAuthService.tokenRequestOverride = nil
            MCPOAuthService.clientSecretAccessorOverride = nil
        }

        let provider = MCPProvider(
            id: providerId,
            name: "p",
            url: "https://mcp.example.com/mcp",
            authType: .oauth,
            oauth: MCPOAuthConfig(
                clientId: "client_abc",
                resource: "https://mcp.example.com",
                tokenEndpoint: "https://auth.example.com/token"
            )
        )
        let original = MCPOAuthTokens(
            accessToken: "AT1",
            refreshToken: "RT1",
            expiresAt: Date().addingTimeInterval(-10),
            scope: nil
        )

        _ = try await MCPOAuthService.refresh(provider: provider, tokens: original, persist: false)

        #expect(capturedForm?["grant_type"] == "refresh_token")
        #expect(capturedForm?["client_id"] == "client_abc")
        #expect(capturedForm?["client_secret"] == "secret-xyz")
    }

    @Test func refreshOmitsClientSecretWhenAccessorReturnsNil() async throws {
        var capturedForm: [String: String]?
        MCPOAuthService.tokenRequestOverride = { _, form in
            capturedForm = form
            return MCPOAuthService.ParsedTokenResponse(
                accessToken: "AT2",
                refreshToken: "RT2",
                expiresAt: Date().addingTimeInterval(3600),
                scope: nil
            )
        }
        // Force public-client behaviour: accessor returns nil for everyone.
        MCPOAuthService.clientSecretAccessorOverride = { _ in nil }
        defer {
            MCPOAuthService.tokenRequestOverride = nil
            MCPOAuthService.clientSecretAccessorOverride = nil
        }

        let provider = MCPProvider(
            name: "p",
            url: "https://mcp.example.com/mcp",
            authType: .oauth,
            oauth: MCPOAuthConfig(
                clientId: "client_abc",
                tokenEndpoint: "https://auth.example.com/token"
            )
        )
        let original = MCPOAuthTokens(
            accessToken: "AT1",
            refreshToken: "RT1",
            expiresAt: Date().addingTimeInterval(-10),
            scope: nil
        )

        _ = try await MCPOAuthService.refresh(provider: provider, tokens: original, persist: false)

        #expect(capturedForm?["client_id"] == "client_abc")
        #expect(capturedForm?["client_secret"] == nil)
    }

    // MARK: - Helpers

    private func makePRM(scopes: [String]?) -> MCPProtectedResourceMetadata {
        let payload: [String: Any] = [
            "resource": "https://mcp.example.com/mcp",
            "authorization_servers": ["https://auth.example.com"],
            "scopes_supported": scopes ?? [],
        ]
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(MCPProtectedResourceMetadata.self, from: data)
    }

    private func makeASM(scopes: [String]?) -> MCPAuthorizationServerMetadata {
        var payload: [String: Any] = [
            "issuer": "https://auth.example.com",
            "authorization_endpoint": "https://auth.example.com/authorize",
            "token_endpoint": "https://auth.example.com/token",
        ]
        if let scopes { payload["scopes_supported"] = scopes }
        let data = try! JSONSerialization.data(withJSONObject: payload)
        return try! JSONDecoder().decode(MCPAuthorizationServerMetadata.self, from: data)
    }
}
