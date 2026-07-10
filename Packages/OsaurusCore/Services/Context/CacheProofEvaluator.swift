//
//  CacheProofEvaluator.swift
//  OsaurusCore
//
//  Driver for the `cache_proof` eval domain: telemetry becomes scored.
//  Runs a prefix-sharing multi-turn conversation (one session id, history
//  echoed like the chat surface) through the real ChatEngine streaming
//  path and snapshots `ModelRuntime.batchDiagnosticsSnapshot()` before
//  and after, so the harness can assert the KV-prefix / SSM-companion /
//  disk-L2 deltas that are telemetry-only everywhere else.
//
//  Lives in OsaurusCore (not the evals kit) because the streaming hint
//  decoders are internal runtime surface and the snapshot topology fields
//  (hybrid model counts) drive the AGENTS.md cache rules: a KV hit alone
//  is not a pass on hybrid-SSM models.
//

import Foundation

/// The scoreable counter deltas of one cache-proof run, plus the topology
/// facts the harness needs to apply the right rule set.
public struct CacheProofTranscript: Sendable, Codable {
    /// Per-turn visible text (post reasoning/stats/tool-hint filtering) —
    /// kept so a failing case shows WHAT the model said, not just counters.
    public let visibleTurns: [String]
    /// Non-nil when a turn failed; completed turns are kept.
    public let error: String?
    /// Non-nil when the host cannot produce cache telemetry at all (no
    /// local MLX engine resolved after the run — remote/foundation route).
    /// The harness maps this to SKIP with this exact reason.
    public let skipReason: String?
    /// Counter deltas across the conversation (after − before; before is
    /// zeroed when no engine existed yet, which is the common cold case).
    public let kvPrefixHitsDelta: Int
    public let kvPrefixMissesDelta: Int
    public let ssmCompanionHitsDelta: Int
    public let ssmCompanionMissesDelta: Int
    public let ssmCompanionReDerivesDelta: Int
    public let diskL2HitsDelta: Int
    public let diskL2MissesDelta: Int
    public let diskL2StoresDelta: Int
    /// True when the resolved engine set contains a hybrid-SSM model —
    /// the harness must then require companion hits, not just KV hits.
    public let hybridTopology: Bool
    /// Token-weighted decode speed across turns, when reported — keeps
    /// every generation row carrying token/s per the runtime proof rules.
    public let decodeTokensPerSecond: Double?

    public init(
        visibleTurns: [String],
        error: String? = nil,
        skipReason: String? = nil,
        kvPrefixHitsDelta: Int = 0,
        kvPrefixMissesDelta: Int = 0,
        ssmCompanionHitsDelta: Int = 0,
        ssmCompanionMissesDelta: Int = 0,
        ssmCompanionReDerivesDelta: Int = 0,
        diskL2HitsDelta: Int = 0,
        diskL2MissesDelta: Int = 0,
        diskL2StoresDelta: Int = 0,
        hybridTopology: Bool = false,
        decodeTokensPerSecond: Double? = nil
    ) {
        self.visibleTurns = visibleTurns
        self.error = error
        self.skipReason = skipReason
        self.kvPrefixHitsDelta = kvPrefixHitsDelta
        self.kvPrefixMissesDelta = kvPrefixMissesDelta
        self.ssmCompanionHitsDelta = ssmCompanionHitsDelta
        self.ssmCompanionMissesDelta = ssmCompanionMissesDelta
        self.ssmCompanionReDerivesDelta = ssmCompanionReDerivesDelta
        self.diskL2HitsDelta = diskL2HitsDelta
        self.diskL2MissesDelta = diskL2MissesDelta
        self.diskL2StoresDelta = diskL2StoresDelta
        self.hybridTopology = hybridTopology
        self.decodeTokensPerSecond = decodeTokensPerSecond
    }
}

/// Driver for the `cache_proof` eval domain. MainActor because engine
/// construction and config-store reads are main-actor-isolated.
@MainActor
public enum CacheProofEvaluator {

    /// Run `queries` as consecutive user turns of ONE conversation and
    /// return the diagnostics deltas across the whole exchange. Turn 2+
    /// shares turn 1's prefix (same session, history echoed), which is
    /// exactly the shape the prefix cache must hit on.
    public static func run(
        queries: [String],
        model: String? = nil,
        maxTokens: Int = 128
    ) async -> CacheProofTranscript {
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        let engine = ChatEngine()
        let sessionId = UUID().uuidString

        let before = await ModelRuntime.batchDiagnosticsSnapshot()

        var history: [ChatMessage] = []
        var visibleTurns: [String] = []
        var runError: String?
        var lastDecodeTps: Double?

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
            do {
                let stream = try await engine.streamChat(request: request)
                for try await delta in stream {
                    if let fragment = StreamingReasoningHint.decode(delta) {
                        reasoning += fragment
                        continue
                    }
                    if let stats = StreamingStatsHint.decode(delta) {
                        if stats.tokensPerSecond > 0 { lastDecodeTps = stats.tokensPerSecond }
                        continue
                    }
                    if StreamingToolHint.isSentinel(delta) { continue }
                    visible += delta
                }
            } catch {
                runError = "turn \(visibleTurns.count + 1)/\(queries.count) failed: \(error)"
                break
            }
            visibleTurns.append(visible)
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

        let after = await ModelRuntime.batchDiagnosticsSnapshot()
        guard let after else {
            // No engine ever resolved: the route never touched local MLX,
            // so there is no cache telemetry to score.
            return CacheProofTranscript(
                visibleTurns: visibleTurns,
                error: runError,
                skipReason:
                    "no local MLX engine resolved for '\(resolvedModel)'; cache telemetry unavailable"
            )
        }

        func delta(_ path: KeyPath<BatchDiagnosticsSnapshot, Int>) -> Int {
            after[keyPath: path] - (before?[keyPath: path] ?? 0)
        }

        return CacheProofTranscript(
            visibleTurns: visibleTurns,
            error: runError,
            kvPrefixHitsDelta: delta(\.prefixHits),
            kvPrefixMissesDelta: delta(\.prefixMisses),
            ssmCompanionHitsDelta: delta(\.ssmCompanionHits),
            ssmCompanionMissesDelta: delta(\.ssmCompanionMisses),
            ssmCompanionReDerivesDelta: delta(\.ssmCompanionReDerives),
            diskL2HitsDelta: delta(\.diskL2Hits),
            diskL2MissesDelta: delta(\.diskL2Misses),
            diskL2StoresDelta: delta(\.diskL2Stores),
            hybridTopology: after.hybridModelCount > 0,
            decodeTokensPerSecond: lastDecodeTps
        )
    }
}
