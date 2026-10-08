//
//  RemoteOneShotStreamingTests.swift
//  osaurusTests
//
//  Which remote providers must serve `generateOneShot` over the streaming
//  path. The ChatGPT/Codex sign-in backend rejects `stream:false` with
//  HTTP 400 `{"detail":"Stream must be set to true"}`, which broke context
//  compaction, titles, and core-model tasks routed to a Codex model.
//

import Testing

@testable import OsaurusCore

struct RemoteOneShotStreamingTests {

    @Test func codexProviderStreamsOneShot() {
        #expect(
            RemoteProviderService.oneShotRequiresStreaming(
                providerType: .openAICodex,
                authType: .openAICodexOAuth
            )
        )
        #expect(
            RemoteProviderService.oneShotRequiresStreaming(
                providerType: .openAICodex,
                authType: .none
            )
        )
    }

    @Test func codexOAuthStreamsOneShotOnAnyWireType() {
        for providerType in RemoteProviderType.allCases {
            #expect(
                RemoteProviderService.oneShotRequiresStreaming(
                    providerType: providerType,
                    authType: .openAICodexOAuth
                ),
                "\(providerType) with Codex sign-in must stream"
            )
        }
    }

    @Test func osaurusAndRouterStreamOneShot() {
        for providerType in [RemoteProviderType.osaurus, .osaurusRouter] {
            #expect(
                RemoteProviderService.oneShotRequiresStreaming(
                    providerType: providerType,
                    authType: .apiKey
                )
            )
        }
    }

    @Test func keyedProvidersKeepNonStreamingOneShot() {
        let nonStreaming: [RemoteProviderType] = [
            .openaiLegacy, .azureOpenAI, .anthropic, .openResponses, .gemini,
        ]
        for providerType in nonStreaming {
            for authType in [RemoteProviderAuthType.none, .apiKey, .xaiOAuth] {
                #expect(
                    !RemoteProviderService.oneShotRequiresStreaming(
                        providerType: providerType,
                        authType: authType
                    ),
                    "\(providerType)/\(authType) should keep the non-streaming one-shot"
                )
            }
        }
    }
}
