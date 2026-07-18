//
//  ConfigureAIStateOAuthCompletionTests.swift
//  OsaurusCoreTests
//
//  Regression coverage for stale browser sign-in completions. OAuth callbacks
//  return credentials asynchronously, so they must not write secrets into a
//  provider form after the user backs out or switches providers.
//

import Foundation
import Testing

@testable import OsaurusCore

@MainActor
struct ConfigureAIStateOAuthCompletionTests {
    @Test func currentOpenRouterCompletionWritesKey() throws {
        let state = ConfigureAIState()
        state.showBYOK()
        state.selectAPIPreset(.openrouter)
        let identity = try setupIdentity(for: state, authMethod: .oauth(.openRouter))
        let requestID = UUID()
        state.apiTestRequestID = requestID
        state.isTesting = true

        let applied = state.applyOAuthCompletionIfCurrent(
            .apiKey("or-live-key"),
            requestID: requestID,
            identity: identity
        )

        #expect(applied)
        #expect(state.apiKey == "or-live-key")
    }

    @Test func staleOpenRouterCompletionAfterBackDoesNotWriteKey() throws {
        let state = ConfigureAIState()
        state.showBYOK()
        state.selectAPIPreset(.openrouter)
        let identity = try setupIdentity(for: state, authMethod: .oauth(.openRouter))
        let requestID = UUID()
        state.apiTestRequestID = requestID
        state.isTesting = true

        state.popFormToPicker(for: .openrouter)
        let applied = state.applyOAuthCompletionIfCurrent(
            .apiKey("or-stale-key"),
            requestID: requestID,
            identity: identity
        )

        #expect(!applied)
        #expect(state.apiKey.isEmpty)
        #expect(state.oauthTokens == nil)
    }

    @Test func staleOpenRouterCompletionAfterProviderSwitchDoesNotWriteKey() throws {
        let state = ConfigureAIState()
        state.showBYOK()
        state.selectAPIPreset(.openrouter)
        let identity = try setupIdentity(for: state, authMethod: .oauth(.openRouter))
        let requestID = UUID()
        state.apiTestRequestID = requestID
        state.isTesting = true

        state.selectAPIPreset(.openai)
        let applied = state.applyOAuthCompletionIfCurrent(
            .apiKey("or-wrong-provider-key"),
            requestID: requestID,
            identity: identity
        )

        #expect(!applied)
        #expect(state.apiKey.isEmpty)
        #expect(state.isTesting == false)
    }

    @Test func staleTokenCompletionAfterProviderSwitchDoesNotWriteTokens() throws {
        let state = ConfigureAIState()
        state.showBYOK()
        state.selectAPIPreset(.openai)
        let identity = try setupIdentity(for: state, authMethod: .oauth(.openAICodex))
        let requestID = UUID()
        state.apiTestRequestID = requestID
        state.isTesting = true

        state.selectAPIPreset(.xai)
        let tokens = RemoteProviderOAuthTokens(
            accessToken: "stale-access",
            refreshToken: "stale-refresh",
            expiresAt: Date().addingTimeInterval(3_600),
            accountId: "acct-stale"
        )
        let applied = state.applyOAuthCompletionIfCurrent(
            .oauthTokens(tokens),
            requestID: requestID,
            identity: identity
        )

        #expect(!applied)
        #expect(state.oauthTokens == nil)
        #expect(state.isTesting == false)
    }

    private func setupIdentity(
        for state: ConfigureAIState,
        authMethod: ProviderPickerAuthMethod
    ) throws -> ProviderSetupTestIdentity {
        let config = try #require(state.resolvedAPIConfig())
        return ProviderSetupTestIdentity(
            config: config,
            authMethod: authMethod,
            apiKeyInput: authMethod == .apiKey ? state.apiKey : nil
        )
    }
}
