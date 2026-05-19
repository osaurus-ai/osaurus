//
//  RemoteProviderResolvedHeadersTests.swift
//  osaurusTests
//
//  Coverage for `RemoteProvider.resolvedHeaders()` — specifically the OpenRouter
//  attribution headers (`HTTP-Referer`, `X-OpenRouter-Title`) that get auto-
//  injected so Osaurus shows up on openrouter.ai/rankings. The attribution
//  block deliberately runs after the user-header merge so any user override
//  still wins.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("RemoteProvider.resolvedHeaders attribution")
struct RemoteProviderResolvedHeadersTests {

    @Test func openRouterHost_injectsAttributionHeaders() {
        let provider = RemoteProvider(
            name: "OpenRouter",
            host: "openrouter.ai",
            basePath: "/api/v1",
            authType: .none,
            providerType: .openaiLegacy
        )

        let headers = provider.resolvedHeaders()
        #expect(headers["HTTP-Referer"] == "https://osaurus.ai")
        #expect(headers["X-OpenRouter-Title"] == "Osaurus")
    }

    @Test func nonOpenRouterHost_doesNotInjectAttributionHeaders() {
        let provider = RemoteProvider(
            name: "Anthropic",
            host: "api.anthropic.com",
            basePath: "/v1",
            authType: .none,
            providerType: .anthropic
        )

        let headers = provider.resolvedHeaders()
        #expect(headers["HTTP-Referer"] == nil)
        #expect(headers["X-OpenRouter-Title"] == nil)
    }

    @Test func openRouterHost_userOverridesWin() {
        let provider = RemoteProvider(
            name: "OpenRouter",
            host: "openrouter.ai",
            basePath: "/api/v1",
            customHeaders: [
                "HTTP-Referer": "https://my-app.example",
                "X-OpenRouter-Title": "MyApp",
            ],
            authType: .none,
            providerType: .openaiLegacy
        )

        let headers = provider.resolvedHeaders()
        #expect(headers["HTTP-Referer"] == "https://my-app.example")
        #expect(headers["X-OpenRouter-Title"] == "MyApp")
    }

    @Test func openRouterHost_isCaseInsensitive() {
        let provider = RemoteProvider(
            name: "OpenRouter",
            host: "OpenRouter.AI",
            basePath: "/api/v1",
            authType: .none,
            providerType: .openaiLegacy
        )

        let headers = provider.resolvedHeaders()
        #expect(headers["HTTP-Referer"] == "https://osaurus.ai")
        #expect(headers["X-OpenRouter-Title"] == "Osaurus")
    }
}
