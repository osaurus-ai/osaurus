//
//  ConfigModelReferenceTests.swift
//  osaurus
//
//  The chat runtime routes `agent.defaultModel` verbatim: local bundle ids
//  as-is, cloud models only via the picker-prefixed "<provider>/<model>"
//  form. These tests pin the resolver that grounds `model:` values from
//  declarative config documents into that contract — the regression was a
//  bare cloud id ("claude-x") being stored verbatim and silently routing
//  nowhere until the user reselected the model in the UI.
//

import Foundation
import Testing

@testable import OsaurusCore

struct ConfigModelReferenceTests {

    private let catalog = ConfigModelReference.Catalog(
        localModelIds: ["OsaurusAI/Gemma-4-QAT", "mlx-community/Qwen-Local"],
        providers: [
            .init(
                prefix: "anthropic", name: "Anthropic",
                models: ["claude-fable-5", "claude-opus-5"]),
            .init(
                prefix: "openrouter", name: "OpenRouter",
                models: ["claude-fable-5", "meta/llama-4"]),
            .init(prefix: "xai", name: "xAI", models: []),
        ]
    )

    @Test
    func foundation_resolvesCaseInsensitively() {
        #expect(
            ConfigModelReference.resolve("Foundation", catalog: catalog)
                == .resolved("foundation"))
    }

    @Test
    func installedLocalId_resolvesToCanonicalCasing() {
        #expect(
            ConfigModelReference.resolve("osaurusai/gemma-4-qat", catalog: catalog)
                == .resolved("OsaurusAI/Gemma-4-QAT"))
    }

    @Test
    func pendingLocalId_fromSameDocumentModelsList_isAccepted() {
        let result = ConfigModelReference.resolve(
            "mlx-community/New-Download", catalog: catalog,
            pendingLocalIds: ["mlx-community/New-Download"])
        #expect(result == .resolved("mlx-community/New-Download"))
    }

    @Test
    func prefixedCloudId_resolvesToCanonicalForm() {
        #expect(
            ConfigModelReference.resolve("Anthropic/Claude-Opus-5", catalog: catalog)
                == .resolved("anthropic/claude-opus-5"))
    }

    @Test
    func prefixedId_withExistingProviderButUnlistedModel_isTrusted() {
        // The provider may be disconnected or its catalog stale; an explicit
        // prefix keeps working (xAI has no discovered models here).
        #expect(
            ConfigModelReference.resolve("xai/grok-5", catalog: catalog)
                == .resolved("xai/grok-5"))
    }

    @Test
    func bareCloudId_uniqueAcrossProviders_isAutoPrefixed() {
        #expect(
            ConfigModelReference.resolve("meta/llama-4", catalog: catalog)
                == .resolved("openrouter/meta/llama-4"))
    }

    @Test
    func bareCloudId_offeredByMultipleProviders_isRejectedWithCandidates() {
        guard
            case .invalid(let message) = ConfigModelReference.resolve(
                "claude-fable-5", catalog: catalog)
        else {
            Issue.record("expected ambiguity rejection")
            return
        }
        #expect(message.contains("anthropic/claude-fable-5"))
        #expect(message.contains("openrouter/claude-fable-5"))
    }

    @Test
    func unknownId_isRejectedWithGuidance() {
        guard
            case .invalid(let message) = ConfigModelReference.resolve(
                "not-a-model", catalog: catalog)
        else {
            Issue.record("expected rejection")
            return
        }
        #expect(message.contains("provider prefix"))
        #expect(message.contains("osaurus_inspect"))
    }

    @Test
    func installedLocalId_winsOverProviderPrefixParsing() {
        // A local repo id contains "/" too; local match must run first even
        // when the first segment collides with nothing provider-shaped.
        let catalog = ConfigModelReference.Catalog(
            localModelIds: ["anthropic/local-lookalike"],
            providers: [.init(prefix: "anthropic", name: "Anthropic", models: ["claude-x"])]
        )
        #expect(
            ConfigModelReference.resolve("anthropic/local-lookalike", catalog: catalog)
                == .resolved("anthropic/local-lookalike"))
    }
}
