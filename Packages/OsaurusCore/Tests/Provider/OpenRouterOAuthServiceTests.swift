//
//  OpenRouterOAuthServiceTests.swift
//  osaurusTests
//
//  Unit coverage for pure OpenRouter PKCE helpers. The interactive sign-in
//  path opens a browser + binds a loopback server, so we only exercise the
//  deterministic URL/PKCE helpers here.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("OpenRouter OAuth helpers")
struct OpenRouterOAuthServiceTests {
    @Test func authorizationURL_containsPKCEParameters() {
        let url = OpenRouterOAuthService.authorizationURL(
            callbackURL: "http://localhost:54321/callback",
            codeChallenge: "challenge",
            state: "state123"
        )
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let params = Dictionary(uniqueKeysWithValues: (components?.queryItems ?? []).map { ($0.name, $0.value ?? "") })

        #expect(components?.scheme == "https")
        #expect(components?.host == "openrouter.ai")
        #expect(components?.path == "/auth")
        #expect(params["callback_url"] == "http://localhost:54321/callback")
        #expect(params["code_challenge"] == "challenge")
        #expect(params["code_challenge_method"] == "S256")
        #expect(params["state"] == "state123")
    }

    @Test func makePKCEPair_usesURLSafeValues() throws {
        let pair = try OpenRouterOAuthService.makePKCEPair()

        #expect(pair.verifier.count >= 43)
        #expect(pair.challenge.count >= 43)
        #expect(!pair.verifier.contains("+"))
        #expect(!pair.verifier.contains("/"))
        #expect(!pair.verifier.contains("="))
        #expect(!pair.challenge.contains("+"))
        #expect(!pair.challenge.contains("/"))
        #expect(!pair.challenge.contains("="))
    }

    @Test func keyExchangeURL_pointsAtAuthKeysEndpoint() {
        #expect(OpenRouterOAuthService.keyExchangeURL.absoluteString == "https://openrouter.ai/api/v1/auth/keys")
    }

    /// Regression for the OpenRouter 409 "Failed to create or update app"
    /// failure: OpenRouter keys its per-user app registration on
    /// `callback_url`, so the URL must stay stable across sign-in attempts
    /// AND should match the docs/Discord-recommended `localhost:3000` so the
    /// server-side dedup fast-path applies.
    @Test func callbackURL_matchesOpenRouterRecommendation() {
        #expect(OpenRouterOAuthService.callbackPort == 3000)
        #expect(OpenRouterOAuthService.callbackURL == "http://localhost:3000/callback")
        // Must NOT clash with the Codex flow's hardcoded port.
        #expect(OpenRouterOAuthService.callbackPort != 1455)
    }

    @Test func attributionConstants_matchSiteIdentity() {
        // These are the single source of truth for both the OAuth app row
        // (see `exchangeCodeForKey`) and the auto-injected headers in
        // `RemoteProvider.resolvedHeaders()`, so the OAuth row and the
        // chat-completion requests present the same identity to OpenRouter.
        let attribution = OpenRouterOAuthService.Attribution.self
        #expect(attribution.host == "openrouter.ai")
        #expect(attribution.referrerURL == "https://osaurus.ai")
        #expect(attribution.appTitle == "Osaurus")
        #expect(attribution.refererHeader == "HTTP-Referer")
        #expect(attribution.titleHeader == "X-OpenRouter-Title")
    }
}
