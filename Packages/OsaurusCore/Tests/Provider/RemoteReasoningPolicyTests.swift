//
//  RemoteReasoningPolicyTests.swift
//  osaurusTests
//
//  Pins RemoteReasoningPolicy resolution + transforms, the single source of
//  truth that the RemoteProviderService reasoning helpers delegate to.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("RemoteReasoningPolicy")
struct RemoteReasoningPolicyTests {

    // MARK: - resolve

    @Test func resolve_miniMaxByHost_inlineThinkAndEmbed() {
        let policy = RemoteReasoningPolicy.resolve(
            providerType: .openaiLegacy,
            host: "api.minimax.io",
            model: "MiniMax-M3"
        )
        #expect(policy.inbound == .inlineThink)
        #expect(policy.outbound == .embedAsThink)
    }

    @Test func resolve_miniMaxByModelOnAggregatorHost_inlineThink() {
        // AtlasCloud serves minimax models under a non-minimax host.
        let policy = RemoteReasoningPolicy.resolve(
            providerType: .openaiLegacy,
            host: "api.atlascloud.ai",
            model: "minimaxai/minimax-m2.7"
        )
        #expect(policy.inbound == .inlineThink)
        #expect(policy.outbound == .embedAsThink)
    }

    @Test func resolve_deepSeek_separateFieldAndEcho() {
        let policy = RemoteReasoningPolicy.resolve(
            providerType: .openaiLegacy,
            host: "api.deepseek.com",
            model: "deepseek-v4-pro"
        )
        #expect(policy.inbound == .separateField)
        #expect(policy.outbound == .echoField)
    }

    @Test func resolve_genericOpenAICompat_separateFieldAndStrip() {
        let policy = RemoteReasoningPolicy.resolve(
            providerType: .openaiLegacy,
            host: "api.openai.com",
            model: "gpt-4o-mini"
        )
        #expect(policy.inbound == .separateField)
        #expect(policy.outbound == .strip)
    }

    @Test func resolve_nonOpenAICompatProviders_alwaysStrip() {
        for providerType: RemoteProviderType in [.anthropic, .openResponses, .openAICodex, .gemini, .osaurus] {
            let policy = RemoteReasoningPolicy.resolve(
                providerType: providerType,
                host: "api.deepseek.com",
                model: "deepseek-v4-pro"
            )
            #expect(policy.inbound == .separateField)
            #expect(policy.outbound == .strip)
        }
    }

    // MARK: - transformOutbound

    private func assistant(reasoning: String?, content: String?) -> ChatMessage {
        ChatMessage(
            role: "assistant",
            content: content,
            tool_calls: nil,
            tool_call_id: nil,
            reasoning_content: reasoning
        )
    }

    @Test func transformOutbound_embedAsThink_foldsReasoningIntoContent() {
        let policy = RemoteReasoningPolicy.resolve(
            providerType: .openaiLegacy,
            host: "api.minimax.io",
            model: "MiniMax-M3"
        )
        let out = policy.transformOutbound([assistant(reasoning: "weighing options", content: "Use plan B.")])
        #expect(out.count == 1)
        #expect(out[0].content == "<think>\nweighing options\n</think>\nUse plan B.")
        #expect(out[0].reasoning_content == nil)
    }

    @Test func transformOutbound_strip_clearsReasoning() {
        let policy = RemoteReasoningPolicy.resolve(
            providerType: .openaiLegacy,
            host: "api.openai.com",
            model: "gpt-4o-mini"
        )
        let out = policy.transformOutbound([assistant(reasoning: "secret", content: "Answer.")])
        #expect(out[0].content == "Answer.")
        #expect(out[0].reasoning_content == nil)
    }

    @Test func transformOutbound_echoField_isIdentity() {
        let policy = RemoteReasoningPolicy.resolve(
            providerType: .openaiLegacy,
            host: "api.deepseek.com",
            model: "deepseek-v4-pro"
        )
        let out = policy.transformOutbound([assistant(reasoning: "chain", content: "Answer.")])
        #expect(out[0].reasoning_content == "chain")
        #expect(out[0].content == "Answer.")
    }

    // MARK: - request-side controls (parity with the old helpers)

    @Test func controls_deepSeekInstruct_disablesThinking() {
        let policy = RemoteReasoningPolicy.resolve(
            providerType: .openaiLegacy,
            host: "api.deepseek.com",
            model: "deepseek-v4-pro"
        )
        let controls = policy.controls(effort: "instruct")
        #expect(controls.effort == nil)
        #expect(controls.thinking == ThinkingConfig(type: "disabled"))
    }

    @Test func controls_deepSeekMax_forwardsEffort() {
        let policy = RemoteReasoningPolicy.resolve(
            providerType: .openaiLegacy,
            host: "api.deepseek.com",
            model: "deepseek-v4-pro"
        )
        let controls = policy.controls(effort: "  MAX  ")
        #expect(controls.effort == "max")
        #expect(controls.thinking == nil)
    }

    @Test func allowsReasoningObject_matchesLegacyRule() {
        #expect(
            RemoteReasoningPolicy.resolve(providerType: .openaiLegacy, host: "openrouter.ai", model: "x")
                .allowsReasoningObject == true
        )
        #expect(
            RemoteReasoningPolicy.resolve(providerType: .openaiLegacy, host: "api.openai.com", model: "x")
                .allowsReasoningObject == false
        )
        #expect(
            RemoteReasoningPolicy.resolve(providerType: .openaiLegacy, host: "api.mistral.ai", model: "mistral-medium-3.5")
                .allowsReasoningObject == false
        )
        #expect(
            RemoteReasoningPolicy.resolve(providerType: .anthropic, host: "api.anthropic.com", model: "x")
                .allowsReasoningObject == false
        )
    }
}
