//
//  EvalRunnerCacheProof.swift
//  OsaurusEvalsKit
//
//  Runner for the `cache_proof` domain — cache telemetry becomes SCORED.
//  Every other lane records `batchDiagnosticsSnapshot` deltas as
//  ride-along telemetry; this lane runs a prefix-sharing multi-turn
//  conversation through `CacheProofEvaluator` and FAILS when the deltas
//  the case declares don't materialize.
//
//  Topology-aware per the AGENTS.md cache rules:
//    - no local MLX engine (remote/foundation route) → SKIP with reason;
//    - hybrid-SSM models must show companion hits (a KV prefix hit alone
//      is not a pass) unless the case explicitly opts out;
//    - an SSM-companion floor on a non-hybrid host is skipped with a note
//      (the counter cannot move there).
//
//  Honors the existing `OSAURUS_EVALS_KV_REGIME` / `OSAURUS_EVALS_PAGED_KV`
//  knobs implicitly — they configure the runtime before any case runs, so
//  the same cases prove regime A/B behavior.
//

import Foundation
@preconcurrency import MLXLMCommon
import OsaurusCore

extension EvalRunner {

    static func runCacheProofCase(
        _ testCase: EvalCase,
        modelId: String
    ) async -> EvalCaseReport {
        let label = testCase.label ?? testCase.id
        guard let exp = testCase.expect.cacheProof else {
            return Self.errored(
                testCase, label: label, modelId: modelId,
                note: "missing `expect.cacheProof`"
            )
        }

        // Minimal prefix-sharing shape when the case doesn't author turns:
        // the same query twice under one session.
        let authoredQueries: [String]
        if let followUps = exp.followUpTurns, !followUps.isEmpty {
            authoredQueries = [testCase.query] + followUps
        } else {
            authoredQueries = [testCase.query, testCase.query]
        }

        let sessionBoundaries = Set(
            (exp.startNewSessionBeforeTurns ?? []).filter {
                $0 > 1 && $0 <= authoredQueries.count
            }
        )
        let expectedSessionCount = 1 + sessionBoundaries.count
        if exp.systemPrompt != nil, exp.systemPromptsPerSession != nil {
            return Self.errored(
                testCase, label: label, modelId: modelId,
                note: "cache proof must set either systemPrompt or "
                    + "systemPromptsPerSession, not both"
            )
        }
        if let prompts = exp.systemPromptsPerSession,
            prompts.count != expectedSessionCount
        {
            return Self.errored(
                testCase, label: label, modelId: modelId,
                note: "systemPromptsPerSession has \(prompts.count) entries; "
                    + "\(expectedSessionCount) session(s) are configured"
            )
        }

        // `--repeat N` executes case trials in one warm process. Persistent
        // L2 entries from trial 1 must not turn trials 2...N into exact warm
        // replays, otherwise a longest-candidate assertion measures earlier
        // trials instead of the current trial's own store/restore lifecycle.
        // Namespace authored system prompts when present; otherwise namespace
        // each authored query. The same marker is retained across every turn
        // inside one trial, so all intended intra-trial prefix relationships
        // remain real while prior trials are content-address incompatible.
        let isolatedInputs = cacheProofTrialInputs(
            queries: authoredQueries,
            systemPrompt: exp.systemPrompt,
            systemPromptsPerSession: exp.systemPromptsPerSession,
            nonce: UUID().uuidString
        )

        let sampler = ResourceSampler.start()
        let started = Date()
        let transcript = await CacheProofEvaluator.run(
            queries: isolatedInputs.queries,
            maxTokens: exp.maxTokens ?? 128,
            thinkingPerTurn: exp.thinkingPerTurn,
            systemPrompt: isolatedInputs.systemPrompt,
            systemPromptsPerSession: isolatedInputs.systemPromptsPerSession,
            startNewSessionBeforeTurns: exp.startNewSessionBeforeTurns ?? []
        )
        let elapsedMs = Date().timeIntervalSince(started) * 1000
        let sample = sampler.stop()

        if let reason = transcript.skipReason {
            return .terminal(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                outcome: .skipped,
                notes: ["SKIP: \(reason)"],
                modelId: modelId
            )
        }
        if let err = transcript.error {
            return EvalCaseReport(
                id: testCase.id,
                label: label,
                domain: testCase.domain,
                query: testCase.query,
                outcome: .errored,
                notes: ["cache-proof run failed: \(err)"],
                modelId: modelId,
                latencyMs: elapsedMs
            )
        }

        var notes: [String] = [
            "repeat isolation: unique content-addressed cache namespace for this trial",
            "turns: \(transcript.visibleTurns.count) · topology: "
                + (transcript.hybridTopology ? "hybrid-SSM" : "full-attention"),
            "deltas: kvHits +\(transcript.kvPrefixHitsDelta) · kvMisses +\(transcript.kvPrefixMissesDelta) · "
                + "ssmHits +\(transcript.ssmCompanionHitsDelta) · ssmReDerives +\(transcript.ssmCompanionReDerivesDelta) · "
                + "diskHits +\(transcript.diskL2HitsDelta) · diskStores +\(transcript.diskL2StoresDelta)",
        ]
        let turnMetrics = transcript.turnMetrics ?? []
        for turn in turnMetrics {
            notes.append(
                "turn \(turn.turnNumber) session \(turn.sessionNumber): "
                    + "restore=\(turn.cacheRestoredTokens.map(String.init) ?? "none") "
                    + "remaining=\(turn.remainingPrefillTokens.map(String.init) ?? "unknown") "
                    + "tier=\(turn.cacheRestoreDetail ?? "none") "
                    + "ttft=\(turn.ttftMs.map { String(format: "%.0fms", $0) } ?? "unknown") "
                    + "prefill=\(turn.prefillTokensPerSecond.map { String(format: "%.1f tok/s", $0) } ?? "unknown") "
                    + "stop=\(turn.stopReason ?? "unknown")"
            )
            if let progress = turn.prefillProgressEvents, !progress.isEmpty {
                notes.append(
                    "turn \(turn.turnNumber) progress: "
                        + compactProgressSummary(progress)
                )
            }
        }
        var passed = true
        func check(_ ok: Bool, pass: String, fail: String) {
            if ok {
                notes.append("ok: \(pass)")
            } else {
                passed = false
                notes.append("FAIL: \(fail)")
            }
        }

        if let floor = exp.minKvPrefixHitsDelta {
            if transcript.hybridTopology {
                // Hybrid-SSM models report reuse on the companion counters
                // (KV prefix counters stay 0 by design), so the same case
                // stays meaningful on both topologies: the reuse floor is
                // applied to the counter that CAN move.
                check(
                    transcript.ssmCompanionHitsDelta >= floor,
                    pass: "reuse floor \(floor) met via SSM companion hits "
                        + "+\(transcript.ssmCompanionHitsDelta) (hybrid topology)",
                    fail: "hybrid topology: SSM companion hits "
                        + "+\(transcript.ssmCompanionHitsDelta) below reuse floor \(floor) "
                        + "(KV floor maps to companion per AGENTS.md cache rules)"
                )
            } else {
                check(
                    transcript.kvPrefixHitsDelta >= floor,
                    pass: "KV prefix hits +\(transcript.kvPrefixHitsDelta) ≥ \(floor)",
                    fail: "KV prefix hits +\(transcript.kvPrefixHitsDelta) below floor \(floor)"
                )
            }
        }
        if let floor = exp.minSsmCompanionHitsDelta {
            if transcript.hybridTopology {
                check(
                    transcript.ssmCompanionHitsDelta >= floor,
                    pass: "SSM companion hits +\(transcript.ssmCompanionHitsDelta) ≥ \(floor)",
                    fail: "SSM companion hits +\(transcript.ssmCompanionHitsDelta) below floor \(floor)"
                )
            } else {
                notes.append(
                    "note: minSsmCompanionHitsDelta \(floor) skipped — non-hybrid topology, "
                        + "counter cannot move"
                )
            }
        }
        if let floor = exp.minDiskL2HitsDelta {
            check(
                transcript.diskL2HitsDelta >= floor,
                pass: "disk-L2 hits +\(transcript.diskL2HitsDelta) ≥ \(floor)",
                fail: "disk-L2 hits +\(transcript.diskL2HitsDelta) below floor \(floor)"
            )
        }
        if let floor = exp.minDiskL2StoresDelta {
            check(
                transcript.diskL2StoresDelta >= floor,
                pass: "disk-L2 stores +\(transcript.diskL2StoresDelta) ≥ \(floor)",
                fail: "disk-L2 stores +\(transcript.diskL2StoresDelta) below floor \(floor)"
            )
        }

        let postFirstTurns = turnMetrics.filter { $0.turnNumber > 1 }
        if let floor = exp.minCacheRestoredTokens {
            let best = postFirstTurns.compactMap(\.cacheRestoredTokens).max() ?? 0
            check(
                best >= floor,
                pass: "structured cache restore \(best) tokens ≥ \(floor)",
                fail: "best structured cache restore \(best) tokens below floor \(floor)"
            )
        }
        if exp.requirePartialCacheRestore == true {
            let partial = postFirstTurns.first {
                ($0.cacheRestoredTokens ?? 0) > 0
                    && ($0.remainingPrefillTokens ?? 0) > 0
            }
            check(
                partial != nil,
                pass: "partial restore proved on turn \(partial?.turnNumber ?? 0): "
                    + "\((partial?.cacheRestoredTokens ?? 0)) restored + "
                    + "\((partial?.remainingPrefillTokens ?? 0)) freshly prefilled",
                fail: "no post-first turn had both restored tokens and a nonzero remaining prefill"
            )
        }
        if exp.requireDiskCacheRestore == true {
            let disk = postFirstTurns.first {
                ($0.cacheRestoredTokens ?? 0) > 0
                    && $0.cacheRestoreDetail?.lowercased() == "disk"
            }
            check(
                disk != nil,
                pass: "structured disk restore proved on turn \(disk?.turnNumber ?? 0)",
                fail: "no post-first cacheRestore event identified tier=disk"
            )
        }
        if let floor = exp.minStructuredCacheRestoreTurns {
            let restoredTurns = postFirstTurns.filter {
                ($0.cacheRestoredTokens ?? 0) > 0
            }
            check(
                restoredTurns.count >= floor,
                pass: "\(restoredTurns.count) post-first turn(s) carried typed cache restore "
                    + "≥ \(floor)",
                fail: "only \(restoredTurns.count) post-first turn(s) carried typed cache "
                    + "restore; need \(floor)"
            )
        }
        if exp.requireFinalDiskCacheRestore == true {
            let final = turnMetrics.last
            let restored = final?.cacheRestoredTokens ?? 0
            let tier = final?.cacheRestoreDetail?.lowercased()
            check(
                restored > 0 && tier == "disk",
                pass: "final turn restored \(restored) tokens from disk",
                fail: "final turn did not carry a nonzero tier=disk restore "
                    + "(restore=\(restored), tier=\(tier ?? "none"))"
            )
        }
        for turnNumber in exp.requireNoCacheRestoreOnTurns ?? [] {
            let turn = turnMetrics.first { $0.turnNumber == turnNumber }
            let restored = turn?.cacheRestoredTokens ?? 0
            check(
                turn != nil && restored == 0,
                pass: "turn \(turnNumber) rejected incompatible cached prompt state",
                fail: turn == nil
                    ? "turn \(turnNumber) has no typed metrics"
                    : "turn \(turnNumber) restored \(restored) token(s) despite an "
                        + "incompatible prompt revision"
            )
        }
        for turnNumber in exp.requireDiskCacheRestoreOnTurns ?? [] {
            let turn = turnMetrics.first { $0.turnNumber == turnNumber }
            let restored = turn?.cacheRestoredTokens ?? 0
            let tier = turn?.cacheRestoreDetail?.lowercased()
            check(
                turn != nil && restored > 0 && tier == "disk",
                pass: "turn \(turnNumber) restored \(restored) tokens from disk",
                fail: turn == nil
                    ? "turn \(turnNumber) has no typed metrics"
                    : "turn \(turnNumber) did not restore from disk "
                        + "(restore=\(restored), tier=\(tier ?? "none"))"
            )
        }
        for turnNumber in exp.requirePartialCacheRestoreOnTurns ?? [] {
            let turn = turnMetrics.first { $0.turnNumber == turnNumber }
            let restored = turn?.cacheRestoredTokens ?? 0
            let remaining = turn?.remainingPrefillTokens ?? 0
            check(
                turn != nil && restored > 0 && remaining > 0,
                pass: "turn \(turnNumber) partially restored \(restored) tokens and "
                    + "prefilled \(remaining)",
                fail: turn == nil
                    ? "turn \(turnNumber) has no typed metrics"
                    : "turn \(turnNumber) lacked a partial restore "
                        + "(restore=\(restored), remaining=\(remaining))"
            )
        }
        if let floor = exp.minFinalRestoreGainTokens {
            let previous = turnMetrics.dropLast().last?.cacheRestoredTokens
            let final = turnMetrics.last?.cacheRestoredTokens
            if let previous, let final {
                let gain = final - previous
                check(
                    gain >= floor,
                    pass: "final restore gain \(gain) tokens "
                        + "(\(previous) → \(final)) ≥ \(floor)",
                    fail: "final restore gain \(gain) tokens "
                        + "(\(previous) → \(final)) below \(floor)"
                )
            } else {
                check(
                    false,
                    pass: "",
                    fail: "minFinalRestoreGainTokens requires typed restore counts on "
                        + "the final two turns"
                )
            }
        }
        if exp.requirePrefillProgressAccounting == true {
            let failures = turnMetrics.compactMap { turn -> String? in
                guard let problem = prefillProgressAccountingProblem(for: turn) else {
                    return nil
                }
                return "turn \(turn.turnNumber): \(problem)"
            }
            check(
                turnMetrics.count == transcript.visibleTurns.count
                    && !turnMetrics.isEmpty
                    && failures.isEmpty,
                pass: "typed prefill progress is monotonic, total-consistent, and complete "
                    + "on every turn",
                fail: failures.isEmpty
                    ? "turn metrics missing for one or more visible turns"
                    : failures.joined(separator: "; ")
            )
        }
        if exp.requireNonEmptyVisibleTurns == true {
            let empty = turnMetrics.filter { $0.visibleCharacterCount == 0 }
            check(
                turnMetrics.count == transcript.visibleTurns.count && empty.isEmpty,
                pass: "every turn produced non-empty visible content",
                fail: "turn metrics missing or empty visible output on turn(s) "
                    + (empty.isEmpty
                        ? "unknown"
                        : empty.map { String($0.turnNumber) }.joined(separator: ","))
            )
        }
        if exp.requireClosedReasoning == true {
            let unclosed = turnMetrics.filter(\.unclosedReasoning)
            check(
                turnMetrics.count == transcript.visibleTurns.count && unclosed.isEmpty,
                pass: "reasoning closed on every turn",
                fail: "turn metrics missing or unclosed reasoning on turn(s) "
                    + (unclosed.isEmpty
                        ? "unknown"
                        : unclosed.map { String($0.turnNumber) }.joined(separator: ","))
            )
        }
        if let ceiling = exp.maxTtftMs {
            let measured = turnMetrics.compactMap(\.ttftMs)
            let over = turnMetrics.filter { ($0.ttftMs ?? 0) > ceiling }
            check(
                turnMetrics.count == transcript.visibleTurns.count
                    && !turnMetrics.isEmpty
                    && measured.count == turnMetrics.count
                    && over.isEmpty,
                pass: String(
                    format: "all %d TTFT readings within %.0f ms",
                    measured.count, ceiling
                ),
                fail: "missing/over-ceiling TTFT on turn(s) "
                    + turnMetrics.filter {
                        $0.ttftMs == nil || ($0.ttftMs ?? 0) > ceiling
                    }.map { String($0.turnNumber) }.joined(separator: ",")
            )
        }

        // AGENTS.md hybrid rule: on a hybrid-SSM model, KV movement without
        // companion movement is NOT reuse proof — fail unless opted out.
        if (exp.requireCompanionOnHybrid ?? true), transcript.hybridTopology {
            let kvMoved = transcript.kvPrefixHitsDelta > 0
            let companionMoved = transcript.ssmCompanionHitsDelta > 0
            check(
                !kvMoved || companionMoved,
                pass: "hybrid rule: companion hits moved with KV hits",
                fail: "hybrid rule: KV hits +\(transcript.kvPrefixHitsDelta) with ZERO companion "
                    + "hits — a KV hit alone is not a pass for hybrid-SSM models"
            )
        }

        // Strong hybrid rule for Qwen 3.5-class rows (Bonsai): companion
        // movement alone is not FULL reuse proof either — older boundaries
        // must demonstrably reach the disk-L2 lane (stores) or come back
        // from it (hits). Non-hybrid topologies note-skip: the requirement
        // is meaningless where no companion cache exists.
        if exp.requireDiskL2EvidenceOnHybrid == true {
            if transcript.hybridTopology {
                let companionMoved =
                    transcript.ssmCompanionHitsDelta > 0
                    || transcript.ssmCompanionReDerivesDelta > 0
                let diskMoved =
                    transcript.diskL2StoresDelta > 0 || transcript.diskL2HitsDelta > 0
                check(
                    companionMoved && diskMoved,
                    pass: "hybrid disk rule: companion "
                        + "(+\(transcript.ssmCompanionHitsDelta) hits/+\(transcript.ssmCompanionReDerivesDelta) rederives) "
                        + "AND disk-L2 (+\(transcript.diskL2HitsDelta) hits/+\(transcript.diskL2StoresDelta) stores) both moved",
                    fail: "hybrid disk rule: companion moved=\(companionMoved) disk-L2 moved=\(diskMoved) "
                        + "— a hybrid row needs BOTH companion and disk-L2 evidence"
                )
            } else {
                notes.append(
                    "note: requireDiskL2EvidenceOnHybrid skipped — non-hybrid topology"
                )
            }
        }

        // Multi-turn memory-growth gate: last-turn footprint − first-turn
        // footprint must stay under the ceiling. Growth back toward the
        // model's on-disk size fails here even when every reuse floor
        // passed — the exact regression the bounded companion LRU exists
        // to prevent.
        if !transcript.footprintAfterTurnMb.isEmpty {
            let series = transcript.footprintAfterTurnMb
                .map { String(format: "%.0f", $0) }
                .joined(separator: " → ")
            notes.append("footprint after each turn (MB): \(series)")
        }
        if let growthCeiling = exp.maxFootprintGrowthMb {
            if let first = transcript.footprintAfterTurnMb.first,
                let last = transcript.footprintAfterTurnMb.last,
                transcript.footprintAfterTurnMb.count >= 2
            {
                let growth = last - first
                check(
                    growth <= growthCeiling,
                    pass: String(
                        format: "footprint growth %.0f MB within %.0f MB across %d turns",
                        growth, growthCeiling, transcript.footprintAfterTurnMb.count
                    ),
                    fail: String(
                        format: "footprint grew %.0f MB across %d turns — EXCEEDS %.0f MB gate",
                        growth, transcript.footprintAfterTurnMb.count, growthCeiling
                    )
                )
            } else {
                check(
                    false,
                    pass: "",
                    fail: "maxFootprintGrowthMb set but per-turn footprint samples unavailable "
                        + "(\(transcript.footprintAfterTurnMb.count) sample(s))"
                )
            }
        }

        // Production-resolved budget gate: the peak footprint must stay
        // within the load budget the memory-safety plan ACTUALLY resolved
        // for this process — which is the simulated 16 GiB budget when
        // OSAURUS_EVALS_SIM_RAM_GB is in force. This ties the eval verdict
        // to the same math production loads under, not a hand-picked MB.
        if exp.gatePeakFootprintToResolvedBudget == true {
            let plan = ServerRuntimeSettingsStore.resolvedMemorySafetyPlan(
                for: ServerRuntimeSettingsStore.snapshot()
            )
            if let budgetBytes = plan.resolvedLoadBudgetBytes {
                let budgetMb = Double(budgetBytes) / (1024 * 1024)
                if let peak = sample.peakPhysFootprintMb {
                    check(
                        peak <= budgetMb,
                        pass: String(
                            format: "peak footprint %.0f MB within resolved budget %.0f MB",
                            peak, budgetMb
                        ),
                        fail: String(
                            format: "peak footprint %.0f MB EXCEEDS resolved budget %.0f MB "
                                + "(plan: %@)",
                            peak, budgetMb, plan.displaySummary
                        )
                    )
                } else {
                    check(
                        false,
                        pass: "",
                        fail: "gatePeakFootprintToResolvedBudget set but ResourceSampler "
                            + "produced no reading"
                    )
                }
            } else {
                notes.append(
                    "note: gatePeakFootprintToResolvedBudget — no budget resolved "
                        + "(unlimited/diagnostic mode); gate not applied"
                )
            }
        }

        if let ceiling = exp.maxPeakPhysFootprintMb {
            if let peak = sample.peakPhysFootprintMb {
                check(
                    peak <= ceiling,
                    pass: String(format: "peak footprint %.0f MB within %.0f MB", peak, ceiling),
                    fail: String(format: "peak footprint %.0f MB EXCEEDS gate %.0f MB", peak, ceiling)
                )
            } else {
                check(
                    false,
                    pass: "",
                    fail: "maxPeakPhysFootprintMb set but ResourceSampler produced no reading"
                )
            }
        }

        if let tps = transcript.decodeTokensPerSecond {
            notes.append(String(format: "decode tok/s: %.1f", tps))
        }

        return EvalCaseReport(
            id: testCase.id,
            label: label,
            domain: testCase.domain,
            query: testCase.query,
            outcome: passed ? .passed : .failed,
            notes: notes,
            modelId: modelId,
            latencyMs: elapsedMs,
            telemetry: EvalCaseTelemetry(
                decodeTokensPerSecond: transcript.decodeTokensPerSecond,
                peakPhysFootprintMb: sample.peakPhysFootprintMb,
                kvPrefixHitsDelta: transcript.kvPrefixHitsDelta,
                kvPrefixMissesDelta: transcript.kvPrefixMissesDelta,
                ssmCompanionHitsDelta: transcript.ssmCompanionHitsDelta,
                ssmCompanionReDerivesDelta: transcript.ssmCompanionReDerivesDelta,
                diskL2HitsDelta: transcript.diskL2HitsDelta,
                diskL2MissesDelta: transcript.diskL2MissesDelta,
                diskL2StoresDelta: transcript.diskL2StoresDelta
            )
        )
    }

    static func cacheProofTrialInputs(
        queries: [String],
        systemPrompt: String?,
        systemPromptsPerSession: [String]?,
        nonce: String
    ) -> (
        queries: [String],
        systemPrompt: String?,
        systemPromptsPerSession: [String]?
    ) {
        let marker =
            "OsaurusEval cache-proof trial \(nonce). "
            + "This identifier is test metadata; do not repeat it."
        if let systemPrompt {
            return (
                queries,
                systemPrompt + "\n\n" + marker,
                nil
            )
        }
        if let systemPromptsPerSession {
            return (
                queries,
                nil,
                systemPromptsPerSession.map { $0 + "\n\n" + marker }
            )
        }
        return (
            queries.map { $0 + "\n\n" + marker },
            nil,
            nil
        )
    }

    /// Deterministic validation of the production progress stream. Returning
    /// nil means the turn has a stable total, bounded/monotonic completed
    /// counts, a restore-to-prefill handoff, and a terminal complete frame.
    static func prefillProgressAccountingProblem(
        for turn: CacheProofTurnMetrics
    ) -> String? {
        guard let events = turn.prefillProgressEvents, !events.isEmpty else {
            return "no typed progress events"
        }
        let positiveTotals = events.map(\.totalUnitCount).filter { $0 > 0 }
        guard let total = positiveTotals.first else {
            return "no positive prompt total"
        }
        guard positiveTotals.allSatisfy({ $0 == total }) else {
            return "prompt total changed within the turn"
        }
        if let promptTokenCount = turn.promptTokenCount, promptTokenCount != total {
            return "metric prompt total \(promptTokenCount) != progress total \(total)"
        }

        let stageOrder = [
            "queued": 0,
            "cacheLookup": 1,
            "cacheRestore": 2,
            "prefill": 3,
            "complete": 4,
        ]
        var previousCompleted = 0
        var previousStage = 0
        for event in events {
            guard let stage = stageOrder[event.stage] else {
                return "unknown progress stage '\(event.stage)'"
            }
            guard stage >= previousStage else {
                return "progress stage regressed at \(event.stage)"
            }
            guard event.completedUnitCount >= 0,
                event.completedUnitCount <= event.totalUnitCount
            else {
                return "completed count \(event.completedUnitCount) outside "
                    + "0...\(event.totalUnitCount)"
            }
            guard event.completedUnitCount >= previousCompleted else {
                return "completed count regressed "
                    + "\(previousCompleted) → \(event.completedUnitCount)"
            }
            previousStage = stage
            previousCompleted = event.completedUnitCount
        }

        guard let final = events.last,
            final.stage == "complete",
            final.completedUnitCount == total
        else {
            return "missing terminal complete=\(total) frame"
        }
        let restored =
            events.filter { $0.stage == "cacheRestore" }
            .map(\.completedUnitCount)
            .max() ?? 0
        if let metricRestored = turn.cacheRestoredTokens, metricRestored != restored {
            return "metric restore \(metricRestored) != progress restore \(restored)"
        }
        if let remaining = turn.remainingPrefillTokens,
            remaining != max(0, total - restored)
        {
            return "remaining prefill \(remaining) != total-restored "
                + "\(max(0, total - restored))"
        }
        if restored > 0,
            let firstPrefill = events.first(where: { $0.stage == "prefill" }),
            firstPrefill.completedUnitCount < restored
        {
            return "prefill restarted below restored boundary "
                + "\(firstPrefill.completedUnitCount) < \(restored)"
        }
        return nil
    }

    /// Keep report notes readable even when chunked prefill emits hundreds of
    /// frames: collapse contiguous stages to first…last completed counts.
    private static func compactProgressSummary(
        _ events: [CacheProofProgressEvent]
    ) -> String {
        var groups: [(stage: String, first: Int, last: Int, total: Int, detail: String?)] = []
        for event in events {
            if let lastIndex = groups.indices.last,
                groups[lastIndex].stage == event.stage,
                groups[lastIndex].total == event.totalUnitCount,
                groups[lastIndex].detail == event.detail
            {
                groups[lastIndex].last = event.completedUnitCount
            } else {
                groups.append(
                    (
                        event.stage,
                        event.completedUnitCount,
                        event.completedUnitCount,
                        event.totalUnitCount,
                        event.detail
                    )
                )
            }
        }
        return groups.map { group in
            let count =
                group.first == group.last
                ? "\(group.last)"
                : "\(group.first)…\(group.last)"
            let detail = group.detail.map { "(\($0))" } ?? ""
            return "\(group.stage):\(count)/\(group.total)\(detail)"
        }.joined(separator: " → ")
    }
}
