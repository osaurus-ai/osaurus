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
