//
//  OpenAICodexOAuthServiceTests.swift
//  osaurusTests
//
//  Unit coverage for pure ChatGPT/Codex OAuth helpers.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("OpenAI Codex OAuth helpers")
struct OpenAICodexOAuthServiceTests {
    @Test func authorizationURL_containsCodexParameters() {
        let url = OpenAICodexOAuthService.authorizationURL(codeChallenge: "challenge", state: "state123")
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components?.scheme == "https")
        #expect(components?.host == "auth.openai.com")
        #expect(params["client_id"] == OpenAICodexOAuthService.clientId)
        #expect(params["redirect_uri"] == OpenAICodexOAuthService.redirectURI)
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["code_challenge"] == "challenge")
        #expect(params["state"] == "state123")
        #expect(params["originator"] == "codex_cli_rs")
        #expect(params["codex_cli_simplified_flow"] == "true")
    }

    @Test func makePKCEPair_usesURLSafeValues() throws {
        let pair = try OpenAICodexOAuthService.makePKCEPair()

        #expect(pair.verifier.count >= 43)
        #expect(pair.challenge.count >= 43)
        #expect(!pair.verifier.contains("+"))
        #expect(!pair.verifier.contains("/"))
        #expect(!pair.verifier.contains("="))
        #expect(!pair.challenge.contains("+"))
        #expect(!pair.challenge.contains("/"))
        #expect(!pair.challenge.contains("="))
    }

    @Test func extractAccountId_readsChatGPTAccountClaim() throws {
        let token = try Self.makeJWT(
            payload: [
                "https://api.openai.com/auth": [
                    "chatgpt_account_id": "acct_123"
                ]
            ]
        )

        #expect(OpenAICodexOAuthService.extractAccountId(from: token) == "acct_123")
    }

    @Test func oauthTokens_expireWithRefreshSkew() {
        let tokens = RemoteProviderOAuthTokens(
            accessToken: "access",
            refreshToken: "refresh",
            expiresAt: Date().addingTimeInterval(30),
            accountId: "acct"
        )

        #expect(tokens.isExpired)
    }

    @Test func supportedModels_containsCurrentCatalog() {
        let models = OpenAICodexOAuthService.supportedModels
        let expected = [
            "gpt-5.5",
            "gpt-5.5-pro",
            "gpt-5.4",
            "gpt-5.4-mini",
            "gpt-5.4-nano",
            "gpt-5.3-codex",
            "gpt-5.3-codex-spark",
        ]
        for slug in expected {
            #expect(models.contains(slug), "static fallback is missing \(slug)")
        }
        #expect(Set(models).count == models.count, "static fallback has duplicate slugs")
    }

    @Test func supportedModels_allUseCodexSlugFormat() {
        // Mirrors the live `/models` filter: Codex-compatible slugs use a
        // dotted version ("gpt-5.4-codex"), chat-only slugs use dashes
        // ("gpt-5-4-thinking") and would 400 if invoked.
        for slug in OpenAICodexOAuthService.supportedModels {
            let matches = slug.range(of: #"^gpt-\d+\.\d+"#, options: .regularExpression) != nil
            #expect(matches, "static fallback slug \(slug) does not use Codex naming")
        }
    }

    @Test func diagnostics_redactOAuthSecretsFromPasteableMessages() {
        let raw = """
            Authorization: Bearer access.secret
            {"access_token":"token-123","refresh_token":"refresh-456","code":"auth-code"}
            code_verifier=verifier-789
            eyJheader.eyJpayload.signature
            """

        let sanitized = OpenAICodexOAuthService.safeDiagnosticFragment(raw, maxLength: 500)

        for secret in ["access.secret", "token-123", "refresh-456", "auth-code", "verifier-789"] {
            #expect(!sanitized.contains(secret), "diagnostic leaked \(secret)")
        }
        #expect(sanitized.range(of: "Authorization", options: .caseInsensitive) == nil)
        #expect(sanitized.range(of: "Bearer", options: .caseInsensitive) == nil)
        #expect(sanitized.contains("***"))
    }

    @Test func diagnostics_explainLoopbackPortCollision() {
        let error = OpenAICodexOAuthError.loopbackBindFailed("Address already in use")
        let message = OpenAICodexOAuthService.diagnosticMessage(for: error)

        #expect(message.contains("localhost:1455"))
        #expect(message.contains("Close any other in-progress sign-in"))
        #expect(message.contains("Address already in use"))
    }

    @Test func diagnostics_distinguishCallbackRejectionAndMissingTokens() {
        let callback = OpenAICodexOAuthService.diagnosticMessage(
            for: OpenAICodexOAuthError.authorizationCallbackRejected("state mismatch from browser callback")
        )
        let missing = OpenAICodexOAuthService.diagnosticMessage(for: OpenAICodexOAuthError.missingSignInTokens)

        #expect(callback.contains("rejected the sign-in callback"))
        #expect(callback.contains("state mismatch"))
        #expect(missing.contains("Missing ChatGPT/Codex sign-in tokens"))
        #expect(missing.contains("Sign in with ChatGPT again"))
    }

    @Test func diagnostics_distinguishModelCatalogHTTPAndDecodeFailures() {
        let http = OpenAICodexOAuthService.diagnosticMessage(
            for: OpenAICodexOAuthError.modelCatalogRequestFailed(
                #"HTTP 401: {"error":"bad","access_token":"secret-token"}"#
            )
        )
        let decode = OpenAICodexOAuthService.diagnosticMessage(
            for: OpenAICodexOAuthError.modelCatalogDecodeFailed(#"{"models":"unexpected"}"#)
        )

        #expect(http.contains("model catalog request failed"))
        #expect(http.contains("HTTP 401"))
        #expect(!http.contains("secret-token"))
        #expect(decode.contains("unreadable Codex model catalog"))
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
