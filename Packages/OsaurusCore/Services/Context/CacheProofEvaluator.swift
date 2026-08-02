//
//  CacheProofEvaluator.swift
//  OsaurusCore
//
//  Driver for the `cache_proof` eval domain: telemetry becomes scored.
//  Runs prefix-sharing turns through the real ChatEngine streaming path,
//  optionally crossing fresh chat/session boundaries, and snapshots
//  `ModelRuntime.batchDiagnosticsSnapshot()` before
//  and after, so the harness can assert the KV-prefix / SSM-companion /
//  disk-L2 deltas that are telemetry-only everywhere else.
//
//  Lives in OsaurusCore (not the evals kit) because the streaming hint
//  decoders are internal runtime surface and the snapshot topology fields
//  (hybrid model counts) drive the AGENTS.md cache rules: a KV hit alone
//  is not a pass on hybrid-SSM models.
//

import Foundation
@preconcurrency import MLXLMCommon

/// One typed prefill-progress frame observed on the production streaming path.
///
/// The stage is stored as its wire value so this public proof artifact does
/// not expose the app-internal UI enum. Keeping every frame lets the eval
/// distinguish a real monotonic restore → prefill → complete lifecycle from a
/// single aggregate cache-hit counter.
public struct CacheProofProgressEvent: Sendable, Codable, Equatable {
    public let stage: String
    public let completedUnitCount: Int
    public let totalUnitCount: Int
    public let detail: String?

    public init(
        stage: String,
        completedUnitCount: Int,
        totalUnitCount: Int,
        detail: String?
    ) {
        self.stage = stage
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
        self.detail = detail
    }
}

/// Structured per-turn proof emitted by the real local streaming path.
///
/// `cacheRestoredTokens` and `remainingPrefillTokens` come from vMLX's
/// `.prefillProgress(stage: .cacheRestore, ...)` event. They are intentionally
/// not inferred from aggregate counters or parsed from debug logs.
public struct CacheProofTurnMetrics: Sendable, Codable {
    public let turnNumber: Int
    public let sessionNumber: Int
    public let ttftMs: Double?
    public let prefillTokensPerSecond: Double?
    public let promptTokenCount: Int?
    public let cacheRestoredTokens: Int?
    public let remainingPrefillTokens: Int?
    public let cacheRestoreDetail: String?
    public let stopReason: String?
    public let unclosedReasoning: Bool
    public let visibleCharacterCount: Int
    public let reasoningCharacterCount: Int
    /// Every typed progress frame in stream order. Optional so transcripts
    /// recorded before this field was introduced remain decodable.
    public let prefillProgressEvents: [CacheProofProgressEvent]?

    public init(
        turnNumber: Int,
        sessionNumber: Int,
        ttftMs: Double?,
        prefillTokensPerSecond: Double?,
        promptTokenCount: Int?,
        cacheRestoredTokens: Int?,
        remainingPrefillTokens: Int?,
        cacheRestoreDetail: String?,
        stopReason: String?,
        unclosedReasoning: Bool,
        visibleCharacterCount: Int,
        reasoningCharacterCount: Int,
        prefillProgressEvents: [CacheProofProgressEvent]? = nil
    ) {
        self.turnNumber = turnNumber
        self.sessionNumber = sessionNumber
        self.ttftMs = ttftMs
        self.prefillTokensPerSecond = prefillTokensPerSecond
        self.promptTokenCount = promptTokenCount
        self.cacheRestoredTokens = cacheRestoredTokens
        self.remainingPrefillTokens = remainingPrefillTokens
        self.cacheRestoreDetail = cacheRestoreDetail
        self.stopReason = stopReason
        self.unclosedReasoning = unclosedReasoning
        self.visibleCharacterCount = visibleCharacterCount
        self.reasoningCharacterCount = reasoningCharacterCount
        self.prefillProgressEvents = prefillProgressEvents
    }
}

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
    /// Physical footprint (MB) sampled after EACH completed turn, in turn
    /// order. The multi-turn growth signal: a bounded companion/KV plan
    /// shows a plateau here; monotonic growth back toward the model's
    /// on-disk size is the Bonsai-class failure this exists to catch.
    /// Empty when the probe failed (treat as "not measured").
    public let footprintAfterTurnMb: [Double]
    /// Per-turn cache/prefill/terminal metrics from the same stream that
    /// produced `visibleTurns`.
    public let turnMetrics: [CacheProofTurnMetrics]?
    /// Exact top-level safetensors bytes when the tested bundle's vMLX load
    /// contract requires those weights to be resident. Nil means either the
    /// bundle is mmap-capable or the requirement could not be established.
    /// This is applicability evidence for an absolute peak-vs-budget gate;
    /// it is not a measured footprint and never replaces the growth gate.
    public let requiredResidentSafetensorsBytes: UInt64?
    /// Stable source attribution for `requiredResidentSafetensorsBytes`.
    public let requiredResidentSafetensorsAttribution: String?

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
        decodeTokensPerSecond: Double? = nil,
        footprintAfterTurnMb: [Double] = [],
        turnMetrics: [CacheProofTurnMetrics] = [],
        requiredResidentSafetensorsBytes: UInt64? = nil,
        requiredResidentSafetensorsAttribution: String? = nil
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
        self.footprintAfterTurnMb = footprintAfterTurnMb
        self.turnMetrics = turnMetrics
        self.requiredResidentSafetensorsBytes = requiredResidentSafetensorsBytes
        self.requiredResidentSafetensorsAttribution =
            requiredResidentSafetensorsAttribution
    }
}

/// Driver for the `cache_proof` eval domain. MainActor because engine
/// construction and config-store reads are main-actor-isolated.
@MainActor
public enum CacheProofEvaluator {

    /// Run `queries` as consecutive user turns and return the diagnostics
    /// deltas across the whole exchange. By default turn 2+ shares turn 1's
    /// prefix in one conversation. `startNewSessionBeforeTurns` clears
    /// history and rotates the session id before the listed one-based turns,
    /// proving disk-backed reuse across fresh chats.
    ///
    /// `thinkingPerTurn`, when provided, sets the request's documented
    /// `enable_thinking` switch per turn (index-aligned with the turn
    /// order; missing indices leave the model default in force). This is
    /// the hybrid-SSM boundary stressor: toggling Thinking mid-conversation
    /// invalidates/re-derives companion states, the exact path the bounded
    /// companion LRU (`ssmCompanionEntryLimit`) must keep from re-growing
    /// to the model's full on-disk size.
    public static func run(
        queries: [String],
        model: String? = nil,
        maxTokens: Int = 128,
        thinkingPerTurn: [Bool]? = nil,
        systemPrompt: String? = nil,
        systemPromptsPerSession: [String]? = nil,
        startNewSessionBeforeTurns: [Int] = []
    ) async -> CacheProofTranscript {
        let resolvedModel =
            model
            ?? ChatConfigurationStore.load().coreModelIdentifier
            ?? "foundation"
        let engine = ChatEngine()
        let residentRequirement = residentSafetensorsRequirement(
            for: resolvedModel
        )
        var sessionId = UUID().uuidString
        var sessionNumber = 1
        let sessionBoundaryTurns = Set(startNewSessionBeforeTurns)

        let before = await ModelRuntime.batchDiagnosticsSnapshot()

        func freshHistory(for sessionNumber: Int) -> [ChatMessage] {
            let sessionPrompt: String?
            if let systemPromptsPerSession,
                systemPromptsPerSession.indices.contains(sessionNumber - 1)
            {
                sessionPrompt = systemPromptsPerSession[sessionNumber - 1]
            } else {
                sessionPrompt = systemPrompt
            }
            guard let sessionPrompt, !sessionPrompt.isEmpty else { return [] }
            return [ChatMessage(role: "system", content: sessionPrompt)]
        }

        var history = freshHistory(for: sessionNumber)
        var visibleTurns: [String] = []
        var runError: String?
        var lastDecodeTps: Double?
        var footprintAfterTurnMb: [Double] = []
        var turnMetrics: [CacheProofTurnMetrics] = []

        for (turnIndex, query) in queries.enumerated() {
            let turnNumber = turnIndex + 1
            if turnNumber > 1, sessionBoundaryTurns.contains(turnNumber) {
                sessionId = UUID().uuidString
                sessionNumber += 1
                history = freshHistory(for: sessionNumber)
            }
            history.append(ChatMessage(role: "user", content: query))
            var request = ChatCompletionRequest(
                model: resolvedModel,
                messages: history,
                temperature: nil,
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
            if let thinkingPerTurn, turnIndex < thinkingPerTurn.count {
                request.enable_thinking = thinkingPerTurn[turnIndex]
            }
            var visible = ""
            var reasoning = ""
            let turnStartedAt = CFAbsoluteTimeGetCurrent()
            var firstModelOutputAt: CFAbsoluteTime?
            var promptTokenCount: Int?
            var cacheRestoredTokens: Int?
            var cacheRestoreDetail: String?
            var prefillTokensPerSecond: Double?
            var stopReason: String?
            var unclosedReasoning = false
            var prefillProgressEvents: [CacheProofProgressEvent] = []
            do {
                let stream = try await engine.streamChat(request: request)
                for try await delta in stream {
                    if let progress = StreamingPrefillProgressHint.decode(delta) {
                        prefillProgressEvents.append(
                            CacheProofProgressEvent(
                                stage: progress.stage.rawValue,
                                completedUnitCount: progress.completedUnitCount,
                                totalUnitCount: progress.totalUnitCount,
                                detail: progress.detail
                            )
                        )
                        if progress.totalUnitCount > 0 {
                            promptTokenCount = max(
                                promptTokenCount ?? 0,
                                progress.totalUnitCount
                            )
                        }
                        if progress.stage == .cacheRestore,
                            progress.completedUnitCount > 0
                        {
                            cacheRestoredTokens = max(
                                cacheRestoredTokens ?? 0,
                                progress.completedUnitCount
                            )
                            cacheRestoreDetail = progress.detail
                        }
                        continue
                    }
                    if let fragment = StreamingReasoningHint.decode(delta) {
                        if firstModelOutputAt == nil {
                            firstModelOutputAt = CFAbsoluteTimeGetCurrent()
                        }
                        reasoning += fragment
                        continue
                    }
                    if let stats = StreamingStatsHint.decode(delta) {
                        if stats.tokensPerSecond > 0 { lastDecodeTps = stats.tokensPerSecond }
                        if let prefill = stats.prefillTokensPerSecond, prefill > 0 {
                            prefillTokensPerSecond = prefill
                        }
                        stopReason = stats.stopReason
                        unclosedReasoning = stats.unclosedReasoning
                        continue
                    }
                    if StreamingToolHint.isSentinel(delta) { continue }
                    if !delta.isEmpty, firstModelOutputAt == nil {
                        firstModelOutputAt = CFAbsoluteTimeGetCurrent()
                    }
                    visible += delta
                }
            } catch {
                runError = "turn \(visibleTurns.count + 1)/\(queries.count) failed: \(error)"
                break
            }
            visibleTurns.append(visible)
            let remainingPrefillTokens: Int?
            if let promptTokenCount, let cacheRestoredTokens {
                remainingPrefillTokens = max(0, promptTokenCount - cacheRestoredTokens)
            } else {
                remainingPrefillTokens = nil
            }
            turnMetrics.append(
                CacheProofTurnMetrics(
                    turnNumber: turnNumber,
                    sessionNumber: sessionNumber,
                    ttftMs: firstModelOutputAt.map {
                        max(0, ($0 - turnStartedAt) * 1000)
                    },
                    prefillTokensPerSecond: prefillTokensPerSecond,
                    promptTokenCount: promptTokenCount,
                    cacheRestoredTokens: cacheRestoredTokens,
                    remainingPrefillTokens: remainingPrefillTokens,
                    cacheRestoreDetail: cacheRestoreDetail,
                    stopReason: stopReason,
                    unclosedReasoning: unclosedReasoning,
                    visibleCharacterCount: visible.count,
                    reasoningCharacterCount: reasoning.count,
                    prefillProgressEvents: prefillProgressEvents
                )
            )
            if let footprint = ProcessMemoryProbe.currentPhysFootprintMB() {
                footprintAfterTurnMb.append(footprint)
            }
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
                    "no local MLX engine resolved for '\(resolvedModel)'; cache telemetry unavailable",
                requiredResidentSafetensorsBytes: residentRequirement?.bytes,
                requiredResidentSafetensorsAttribution: residentRequirement?.attribution
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
            decodeTokensPerSecond: lastDecodeTps,
            footprintAfterTurnMb: footprintAfterTurnMb,
            turnMetrics: turnMetrics,
            requiredResidentSafetensorsBytes: residentRequirement?.bytes,
            requiredResidentSafetensorsAttribution: residentRequirement?.attribution
        )
    }

    private static func residentSafetensorsRequirement(
        for model: String
    ) -> (bytes: UInt64, attribution: String)? {
        guard let installed = ModelManager.findInstalledMLXModel(named: model)
        else { return nil }
        let facts = LoadBundleFacts.inspect(bundleURL: installed.localDirectory)
        guard facts.requiresResidentSafetensors,
            facts.totalSafetensorsBytes > 0
        else { return nil }
        return (
            facts.totalSafetensorsBytes,
            "vmlx_load_bundle_facts_requires_resident_safetensors"
        )
    }
}
