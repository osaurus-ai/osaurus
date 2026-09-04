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
    /// Incremental raw-envelope delta of a tool call still being generated.
    ///
    /// Translated from vmlx-swift's `Generation.toolCallProgress(String)` (local
    /// MLX). The payload is the format-specific envelope text as it streams (not
    /// parsed arguments), so a UI can preview a long call — e.g. a file write —
    /// as it is written instead of showing a silent gap for the whole call. The
    /// fully parsed call still arrives once as `.toolInvocation` when the
    /// envelope closes, so `.toolInvocation` remains the actionable tool event.
    case toolCallProgress(String)
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
    /// `mtp` carries vmlx's `GenerateCompletionInfo.nativeMTPStats` when the
    /// native-MTP iterator produced these tokens, and `nil` for every other
    /// decode path (plain AR, dFlash-2, remote). `nil` therefore covers both
    /// "not requested" and "requested but gate-excluded" — the distinction
    /// still lives in the vmlx gate, but carrying the stats end-to-end is
    /// what lets an eval report PROVE which decode path a step ran on
    /// instead of inferring it from a stderr line.
    case completionInfo(
        tokenCount: Int,
        tokensPerSecond: Double,
        unclosedReasoning: Bool,
        stopReason: String?,
        promptTokensPerSecond: Double,
        mtp: MTPStatsSummary?
    )
}

/// Compact, transport-friendly projection of vmlx's
/// `NativeMTPGenerationStats` for one generation: the depth actually in
/// effect, the depth after adaptive downshifts, and the draft/accept/reject
/// counters an MTP control needs to verify itself against.
struct MTPStatsSummary: Sendable, Equatable {
    /// Draft depth in effect at the start of generation (post policy cap).
    let depth: Int
    /// Draft depth at the end of generation, after adaptive downshifts.
    let activeDepth: Int
    /// Verify cycles executed.
    let verifyCalls: Int
    /// Draft tokens accepted across all verify cycles
    /// (Σ n · acceptedByDepth[n]).
    let acceptedDraftTokens: Int
    /// Bonus tokens sampled from the target after full acceptance.
    let bonusTokens: Int
    /// Rejected draft tokens.
    let rejectedTokens: Int
    /// Tokens produced by the autoregressive fallback path.
    let arFallbackTokens: Int
    /// Number of adaptive depth downshifts.
    let adaptiveDownshifts: Int
    /// Why the adaptive controller fell back to AR decode, or nil.
    let adaptiveFallbackReason: String?
    /// Average tokens committed per verify cycle over the speculative output
    /// (`speculativeOutputTokens / verifyCalls`). This is the honest,
    /// artifact-free measure of how much speculation actually paid: 1.0 means
    /// each verify committed a single token (no better than plain autoregressive
    /// decode), and depth+1 is the ceiling. It is NOT reconstructible from the
    /// accepted/rejected counters — `rejectedTokens` increments at most once per
    /// cycle, so `accepted/(accepted+rejected)` reads high at depth ≥ 2 and does
    /// NOT match the ratio the adaptive controller downshifts on. `avgAcceptProbability`
    /// is deliberately not carried: native MTP forces greedy sampling, under which
    /// it is always 0.
    ///
    /// Defaulted because the compact streaming wire (`StreamingStatsHint`,
    /// positional) does not carry it: a summary reconstructed from the wire in
    /// `ModelService` gets 0, which is harmless — the wire feeds ChatView, which
    /// ignores `mtp` entirely. The Live Activity readout reads the mapper's full
    /// `GenerateCompletionInfo.nativeMTPStats`, so it always has the real value.
    var avgCommittedPerVerify: Double = 0
}
