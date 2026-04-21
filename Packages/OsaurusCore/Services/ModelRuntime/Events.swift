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
    /// `GenerationEventMapper` from vmlx-swift-lm's `Generation.reasoning(String)`
    /// case (local MLX) or synthesised by `RemoteProviderService` from
    /// streamed `reasoning_content` (remote OpenAI-compatible providers).
    /// Carried end-to-end through `StreamingReasoningHint` to the HTTP
    /// `reasoning_content` field, the ChatView Think panel, and the plugin
    /// streaming hint.
    case reasoning(String)
    case toolInvocation(name: String, argsJSON: String)
    case completionInfo(tokenCount: Int, tokensPerSecond: Double)
}
