//
//  ReasoningChannelEvaluator.swift
//  OsaurusCore
//
//  Multi-turn chat driver for the `reasoning_channel` eval domain. Runs
//  plain (tool-free) chat turns through the real ChatEngine streaming
//  path — the same delta routing the chat surface uses — and records,
//  PER TURN, what landed on the visible channel vs the structured
//  reasoning channel, plus the runtime's own unclosed-reasoning flag.
//
//  This is the lane that makes the AGENTS.md reasoning non-negotiables
//  scoreable: raw parser markers must never leak into visible text,
//  reasoning must ride the structured channel, and multi-turn runs must
//  stay coherent without echoing an earlier turn's reasoning.
//
//  Lives in OsaurusCore because typed Responses generation and
//  `LocalReasoningCapability` are internal runtime surface.
//

import Foundation

/// One terminal chat turn, split by channel; interrupted rows remain diagnostic.
public struct ReasoningChannelTurn: Sendable, Codable {
    /// Text that streamed on the visible content channel.
    public let visibleText: String
    /// Text that streamed on the structured reasoning channel
    /// (typed reasoning deltas). Empty when the model produced
    /// no reasoning output for the turn.
    public let reasoningText: String
    /// The runtime's own end-of-step signal that a reasoning span was
    /// opened but never closed (typed completion unclosedReasoning).
    /// A true value is a parser-boundary violation regardless of what
    /// the visible text looks like.
    public let unclosedReasoning: Bool
    /// Authoritative generated-token count from completion, when
    /// the path emitted one.
    public let tokenCount: Int?
    /// Token-weighted decode speed for the turn (tokens/sec), when the
    /// completion reported one — keeps every generation row carrying
    /// token/s per the runtime proof rules.
    public let decodeTokensPerSecond: Double?

    public init(
        visibleText: String,
        reasoningText: String,
        unclosedReasoning: Bool,
        tokenCount: Int? = nil,
        decodeTokensPerSecond: Double? = nil
    ) {
        self.visibleText = visibleText
        self.reasoningText = reasoningText
        self.unclosedReasoning = unclosedReasoning
        self.tokenCount = tokenCount
        self.decodeTokensPerSecond = decodeTokensPerSecond
    }
}

/// Result of a reasoning-channel run: the per-turn channel splits, or
/// the error that stopped it (completed turns are kept for forensics).
public struct ReasoningChannelTranscript: Sendable, Codable {
    public let turns: [ReasoningChannelTurn]
    /// Non-nil when a turn failed; terminal diagnostic rows are retained.
    public let error: String?
    /// Whether the resolved model advertises a reasoning channel at all
    /// (chat-template / runtime-config detection). Cases use this to
    /// SKIP reasoning-required assertions on models with no channel.
    public let modelSupportsThinking: Bool

    public init(
        turns: [ReasoningChannelTurn],
        error: String? = nil,
        modelSupportsThinking: Bool
    ) {
        self.turns = turns
        self.error = error
        self.modelSupportsThinking = modelSupportsThinking
    }
}

/// Driver for the `reasoning_channel` eval domain. MainActor for the
/// same reason as the sibling evaluators: engine construction and
/// config-store reads are main-actor-isolated.
@MainActor
public enum ReasoningChannelEvaluator {

    /// Whether `modelId` has a detectable reasoning channel (thinking
    /// template kwarg, `<think>`-style tags, or jang-config reasoning).
    /// Public wrapper so the eval harness can gate cases without
    /// reaching internal capability surface.
    public static func modelSupportsThinking(modelId: String) -> Bool {
        LocalReasoningCapability.capability(forModelId: modelId).supportsThinking
    }

    /// Run `queries` as consecutive user turns of ONE conversation
    /// (assistant replies — visible text plus `reasoning_content` — are
    /// echoed back into history exactly as the chat surface does) and
    /// return the per-turn channel split.
    public static func run(
        queries: [String],
        model: String? = nil,
        maxTokens: Int = 1_024,
        temperature: Float? = nil
    ) async -> ReasoningChannelTranscript {
        let resolvedModel = model ?? ChatConfigurationStore.load().coreModelIdentifier ?? "foundation"
        return await runConversation(
            queries: queries, model: resolvedModel, maxTokens: maxTokens, temperature: temperature,
            supportsThinking: modelSupportsThinking(modelId: resolvedModel), engine: ChatEngine()
        )
    }

    static func runConversation(
        queries: [String], model: String, maxTokens: Int, temperature: Float? = nil,
        supportsThinking: Bool, engine: any ResponsesEngineProtocol
    ) async -> ReasoningChannelTranscript {
        let sessionId = UUID().uuidString
        var history: [ChatMessage] = []
        var turns: [ReasoningChannelTurn] = []
        for (index, query) in queries.enumerated() {
            history.append(ChatMessage(role: "user", content: query))
            let request = ResponsesInferenceRequest(
                model: model, input: history,
                generation: ResponsesGenerationOptions(temperature: temperature, maxOutputTokens: maxTokens),
                sessionID: sessionId
            )
            do {
                let result = try await engine.completeResponse(request: request, endAt: .streamEnd)
                turns.append(ReasoningChannelTurn(
                    visibleText: result.text, reasoningText: result.reasoning,
                    unclosedReasoning: result.completion.unclosedReasoning,
                    tokenCount: result.completion.tokenCount,
                    decodeTokensPerSecond: result.completion.tokensPerSecond
                ))
                // Native reasoning, encrypted/provider Items and their IDs must
                // survive the next request; never reconstruct a text-only echo.
                history.append(try result.completedAssistantInput())
            } catch {
                return ReasoningChannelTranscript(
                    turns: turns, error: "turn \(index + 1)/\(queries.count) failed: \(error)",
                    modelSupportsThinking: supportsThinking
                )
            }
        }
        return ReasoningChannelTranscript(turns: turns, modelSupportsThinking: supportsThinking)
    }
}
