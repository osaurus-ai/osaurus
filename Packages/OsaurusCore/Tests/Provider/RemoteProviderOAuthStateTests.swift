//
//  RemoteProviderOAuthStateTests.swift
//  osaurusTests
//
//  Covers the durable requiresAuth state: classification of permanent OAuth
//  refresh failures (invalid_grant / invalid_token on 400/401) and the
//  manager's handlePermanentOAuthFailure state transition.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite(.serialized)
@MainActor
struct RemoteProviderOAuthStateTests {

    // MARK: - Classification

    @Test func classifiesInvalidGrantOn400AsPermanent() {
        let error = OpenAICodexOAuthError.tokenRequestFailed(
            #"HTTP 400: {"error":"invalid_grant","error_description":"Token expired"}"#
        )
        #expect(RemoteProviderManager.isPermanentOAuthFailure(error))
    }

    @Test func classifiesInvalidTokenOn401AsPermanent() {
        let error = XAIOAuthError.tokenRequestFailed(
            #"HTTP 401: {"error":"invalid_token"}"#
        )
        #expect(RemoteProviderManager.isPermanentOAuthFailure(error))
    }

    @Test func networkErrorIsNotPermanent() {
        let error = OpenAICodexOAuthError.tokenRequestFailed(
            "Network error: The Internet connection appears to be offline."
        )
        #expect(!RemoteProviderManager.isPermanentOAuthFailure(error))
    }

    @Test func serverErrorIsNotPermanent() {
        let error = XAIOAuthError.tokenRequestFailed("HTTP 503: upstream unavailable")
        #expect(!RemoteProviderManager.isPermanentOAuthFailure(error))
    }

    @Test func http400WithoutOAuthErrorCodeIsNotPermanent() {
        // A 400 that is not an OAuth grant failure (e.g. malformed request)
        // should stay retryable rather than wiping the user's tokens.
        let error = OpenAICodexOAuthError.tokenRequestFailed("HTTP 400: bad request shape")
        #expect(!RemoteProviderManager.isPermanentOAuthFailure(error))
    }

    @Test func unrelatedErrorsAreNotPermanent() {
        struct Boom: Error {}
        #expect(!RemoteProviderManager.isPermanentOAuthFailure(Boom()))
        #expect(!RemoteProviderManager.isPermanentOAuthFailure(URLError(.timedOut)))
    }

    // MARK: - State transition

    @Test func handlePermanentOAuthFailure_setsDurableRequiresAuthState() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let provider = RemoteProvider(
                name: "Codex Test",
                host: "127.0.0.1",
                basePath: "/v1",
                authType: .openAICodexOAuth,
                providerType: .openaiLegacy
            )
            manager._testInstallConnectedProvider(provider, discoveredModels: ["gpt-test"])
            defer { manager._testRemoveProviders(ids: [provider.id]) }

            manager.handlePermanentOAuthFailure(providerId: provider.id)

            let state = manager.providerStates[provider.id]
            #expect(state?.requiresAuth == true)
            #expect(state?.isConnected == false)
            #expect(state?.isConnecting == false)
            #expect(state?.lastFailureWasTransient == false)
            #expect(state?.discoveredModels.isEmpty == true)
            #expect(state?.lastError?.isEmpty == false)
        }
    }

    @Test func successfulConnectClearsRequiresAuth() async throws {
        await RemoteProviderTestLock.shared.run {
            let manager = RemoteProviderManager.shared
            let provider = RemoteProvider(
                name: "Recovers",
                host: "127.0.0.1",
                basePath: "/v1",
                authType: .none,
                providerType: .openaiLegacy
            )
            manager._testInstallConnectedProvider(provider, discoveredModels: [])
            defer { manager._testRemoveProviders(ids: [provider.id]) }

            var state = manager.providerStates[provider.id]!
            state.requiresAuth = true
            state.isConnected = false
            manager._testSetState(state, for: provider.id)

            manager.testFetchModelsOverride = { _ in ["model-a"] }
            defer { manager.testFetchModelsOverride = nil }
            try? await manager.connect(providerId: provider.id)

            let after = manager.providerStates[provider.id]
            #expect(after?.requiresAuth == false)
            #expect(after?.isConnected == true)
        }
    }
}
