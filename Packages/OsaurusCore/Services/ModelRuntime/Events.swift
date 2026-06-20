//
//  Events.swift
//  osaurus
//
//  Typed events emitted by the unified generation pipeline.
//

import Foundation

enum ModelRuntimeEvent: Sendable {
    case tokens(String)
    /// Reasoning text (thinking / chain-of-thought). Translated by
    /// `GenerationEventMapper` from vmlx-swift's `Generation.reasoning(String)`
    /// case (local MLX) or synthesised by `RemoteProviderService` from
    /// streamed `reasoning_content` (remote OpenAI-compatible providers).
    /// Carried end-to-end through `StreamingReasoningHint` to the HTTP
    /// `reasoning_content` field, the ChatView Think panel, and the plugin
    /// streaming hint.
    case reasoning(String)
    /// Real prompt-processing progress before first generated token.
    ///
    /// This is emitted from vmlx-swift's `Generation.prefillProgress` and
    /// intentionally carries stage + completed/total units instead of a
    /// wall-clock estimate. Consumers can render a determinate percentage when
    /// total units are known, or stage text when the runtime is still doing
    /// cache lookup/restore work.
    case prefillProgress(PrefillProgressState)
    case toolInvocation(name: String, argsJSON: String)
    /// Completion stats for the just-finished generation.
    ///
    /// `unclosedReasoning` mirrors vmlx's `GenerateCompletionInfo.unclosedReasoning`:
    /// `true` when the stream ended while the reasoning parser was still
    /// inside a `<think>…</think>` block — i.e. the model got "trapped"
    /// in chain-of-thought without emitting a final answer in the visible
    /// content channel. Reasoning-trained Qwen3.6-A3B / DeepSeek-V4
    /// fine-tunes hit this on validation-style prompts ("give me a 20-digit
    /// number") because their training data extends thought through
    /// arbitrary self-verification. `false` for non-reasoning models or
    /// for streams that emitted `</think>` cleanly.
    case completionInfo(
        tokenCount: Int,
        tokensPerSecond: Double,
        unclosedReasoning: Bool,
        stopReason: String?,
        promptTokensPerSecond: Double
    )
}
