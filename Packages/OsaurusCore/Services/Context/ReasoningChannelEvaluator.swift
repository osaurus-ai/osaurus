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
//  Lives in OsaurusCore (not the evals kit) because the streaming hint
//  decoders and `LocalReasoningCapability` are internal runtime surface.
//

import Foundation

/// One completed chat turn, split by channel.
public struct ReasoningChannelTurn: Sendable, Codable {
    /// Text that streamed on the visible content channel.
    public let visibleText: String
    /// Text that streamed on the structured reasoning channel
    /// (`StreamingReasoningHint` deltas). Empty when the model produced
    /// no reasoning output for the turn.
    public let reasoningText: String
    /// The runtime's own end-of-step signal that a reasoning span was
    /// opened but never closed (`StreamingStatsHint.unclosedReasoning`).
    /// A true value is a parser-boundary violation regardless of what
    /// the visible text looks like.
    public let unclosedReasoning: Bool
    /// Authoritative generated-token count from the stats hint, when
    /// the path emitted one.
    public let tokenCount: Int?
    /// Token-weighted decode speed for the turn (tokens/sec), when the
    /// stats hint reported one — keeps every generation row carrying
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
    /// Non-nil when a turn failed; `turns` holds the turns that finished.
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
        maxTokens: Int = 1_024
    ) async -> ReasoningChannelTranscript {
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        let supportsThinking = modelSupportsThinking(modelId: resolvedModel)
        let engine = ChatEngine()
        // One session for the whole conversation so multi-turn prefix
        // reuse behaves like production.
        let sessionId = UUID().uuidString

        var history: [ChatMessage] = []
        var turns: [ReasoningChannelTurn] = []

        for query in queries {
            history.append(ChatMessage(role: "user", content: query))
            let request = ChatCompletionRequest(
                model: resolvedModel,
                messages: history,
                temperature: 0.0,
                max_tokens: maxTokens,
                stream: true,
                top_p: nil,
                frequency_penalty: nil,
                presence_penalty: nil,
                stop: nil,
                n: nil,
                tools: nil,
                tool_choice: nil,
                session_id: sessionId
            )

            var visible = ""
            var reasoning = ""
            var unclosed = false
            var tokenCount: Int?
            var decodeTps: Double?
            do {
                let stream = try await engine.streamChat(request: request)
                for try await delta in stream {
                    if let fragment = StreamingReasoningHint.decode(delta) {
                        reasoning += fragment
                        continue
                    }
                    if let stats = StreamingStatsHint.decode(delta) {
                        if stats.unclosedReasoning { unclosed = true }
                        if stats.tokenCount > 0 { tokenCount = stats.tokenCount }
                        if stats.tokensPerSecond > 0 { decodeTps = stats.tokensPerSecond }
                        continue
                    }
                    if StreamingToolHint.isSentinel(delta) { continue }
                    visible += delta
                }
            } catch {
                return ReasoningChannelTranscript(
                    turns: turns,
                    error: "turn \(turns.count + 1)/\(queries.count) failed: \(error)",
                    modelSupportsThinking: supportsThinking
                )
            }

            turns.append(
                ReasoningChannelTurn(
                    visibleText: visible,
                    reasoningText: reasoning,
                    unclosedReasoning: unclosed,
                    tokenCount: tokenCount,
                    decodeTokensPerSecond: decodeTps
                )
            )
            // Echo the assistant turn — with its reasoning — back into
            // history like the chat surface (DeepSeek-style providers
            // 400 without `reasoning_content` on assistant turns).
            history.append(
                ChatMessage(
                    role: "assistant",
                    content: visible.isEmpty ? nil : visible,
                    tool_calls: nil,
                    tool_call_id: nil,
                    reasoning_content: reasoning.isEmpty ? nil : reasoning
                )
            )
        }

        return ReasoningChannelTranscript(
            turns: turns,
            modelSupportsThinking: supportsThinking
        )
    }
}
