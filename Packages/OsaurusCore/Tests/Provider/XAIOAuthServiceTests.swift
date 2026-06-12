//
//  XAIOAuthServiceTests.swift
//  osaurusTests
//
//  Unit coverage for pure xAI (Grok) OAuth helpers.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("xAI Grok OAuth helpers")
struct XAIOAuthServiceTests {
    @Test func authorizationURL_containsXAIParameters() {
        let endpoint = URL(string: "https://auth.x.ai/oauth/authorize")!
        let url = XAIOAuthService.authorizationURL(
            authorizationEndpoint: endpoint,
            codeChallenge: "challenge",
            state: "state123",
            nonce: "nonce456"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components?.scheme == "https")
        #expect(components?.host == "auth.x.ai")
        #expect(params["response_type"] == "code")
        #expect(params["client_id"] == XAIOAuthService.clientId)
        #expect(params["redirect_uri"] == XAIOAuthService.redirectURI)
        #expect(params["scope"] == XAIOAuthService.scope)
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["code_challenge"] == "challenge")
        #expect(params["state"] == "state123")
        #expect(params["nonce"] == "nonce456")
        #expect(params["plan"] == "generic")
    }

    @Test func redirectURI_usesRegisteredLoopback() {
        #expect(XAIOAuthService.redirectURI == "http://127.0.0.1:56121/callback")
    }

    @Test func scope_requestsOfflineAccessAndAPIAccess() {
        let scopes = Set(XAIOAuthService.scope.split(separator: " ").map(String.init))
        #expect(scopes.contains("offline_access"))
        #expect(scopes.contains("api:access"))
        #expect(scopes.contains("grok-cli:access"))
    }

    @Test func makePKCEPair_usesURLSafeValues() throws {
        let pair = try XAIOAuthService.makePKCEPair()

        #expect(pair.verifier.count >= 43)
        #expect(pair.challenge.count >= 43)
        for fragment in ["+", "/", "="] {
            #expect(!pair.verifier.contains(fragment))
            #expect(!pair.challenge.contains(fragment))
        }
    }

    @Test func extractAccountId_readsSubClaim() throws {
        let idToken = try Self.makeJWT(payload: ["sub": "user_xyz", "email": "grok@example.com"])

        #expect(XAIOAuthService.extractAccountId(idToken: idToken, accessToken: "ignored") == "user_xyz")
    }

    @Test func extractAccountId_fallsBackToAccessTokenThenEmpty() throws {
        let accessToken = try Self.makeJWT(payload: ["sub": "from_access"])

        #expect(XAIOAuthService.extractAccountId(idToken: nil, accessToken: accessToken) == "from_access")
        #expect(XAIOAuthService.extractAccountId(idToken: nil, accessToken: "not-a-jwt") == "")
    }

    @Test func isTrustedEndpoint_acceptsXAIDomainsOnly() {
        #expect(XAIOAuthService.isTrustedEndpoint("https://auth.x.ai/oauth/token"))
        #expect(XAIOAuthService.isTrustedEndpoint("https://x.ai/oauth/authorize"))
        #expect(!XAIOAuthService.isTrustedEndpoint("http://auth.x.ai/oauth/token"))
        #expect(!XAIOAuthService.isTrustedEndpoint("https://auth.evil.com/oauth/token"))
        #expect(!XAIOAuthService.isTrustedEndpoint("https://notx.ai.evil.com/token"))
        #expect(!XAIOAuthService.isTrustedEndpoint("not a url"))
    }

    @Test func supportedModels_provideOAuthCatalogWithGrok43Default() {
        let models = XAIOAuthService.supportedModels
        #expect(models.first == "grok-4.3")
        #expect(models.contains("grok-build-0.1"))
        #expect(Set(models).count == models.count, "static catalog has duplicate slugs")
    }

    @Test func makeProvider_usesOpenAICompatibleXAIShape() {
        let provider = XAIOAuthService.makeProvider()

        #expect(provider.host == "api.x.ai")
        #expect(provider.basePath == "/v1")
        #expect(provider.authType == .xaiOAuth)
        #expect(provider.providerType == .openaiLegacy)
        #expect(provider.enabled)
    }

    @Test func diagnostics_redactOAuthSecretsFromPasteableMessages() {
        let raw = """
            Authorization: Bearer access.secret
            {"access_token":"token-123","refresh_token":"refresh-456","code":"auth-code"}
            code_verifier=verifier-789
            eyJheader.eyJpayload.signature
            """

        let sanitized = XAIOAuthService.safeDiagnosticFragment(raw, maxLength: 500)

        for secret in ["access.secret", "token-123", "refresh-456", "auth-code", "verifier-789"] {
            #expect(!sanitized.contains(secret), "diagnostic leaked \(secret)")
        }
        #expect(sanitized.range(of: "Authorization", options: .caseInsensitive) == nil)
        #expect(sanitized.contains("***"))
    }

    @Test func diagnostics_explainLoopbackPortCollision() {
        let error = XAIOAuthError.loopbackBindFailed("Address already in use")
        let message = XAIOAuthService.diagnosticMessage(for: error)

        // Port number may be locale-formatted with a thousands separator
        // when interpolated inside a localized string.
        let digitsOnly = String(message.filter(\.isNumber))
        #expect(digitsOnly.contains("56121"))
        #expect(message.contains("Close any other in-progress sign-in"))
        #expect(message.contains("Address already in use"))
    }

    @Test func diagnostics_distinguishCallbackRejectionAndMissingTokens() {
        let callback = XAIOAuthService.diagnosticMessage(
            for: XAIOAuthError.authorizationCallbackRejected("state mismatch from browser callback")
        )
        let missing = XAIOAuthService.diagnosticMessage(for: XAIOAuthError.missingSignInTokens)

        #expect(callback.contains("rejected the sign-in callback"))
        #expect(callback.contains("state mismatch"))
        #expect(missing.contains("Missing Grok sign-in tokens"))
    }

    private static func makeJWT(payload: [String: Any]) throws -> String {
        let headerData = try JSONSerialization.data(withJSONObject: ["alg": "none"])
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        return [
            base64URL(headerData),
            base64URL(payloadData),
            "signature",
        ].joined(separator: ".")
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
