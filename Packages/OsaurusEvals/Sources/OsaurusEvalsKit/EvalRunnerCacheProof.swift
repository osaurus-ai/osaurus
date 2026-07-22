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
        let queries: [String]
        if let followUps = exp.followUpTurns, !followUps.isEmpty {
            queries = [testCase.query] + followUps
        } else {
            queries = [testCase.query, testCase.query]
        }

        let sampler = ResourceSampler.start()
        let started = Date()
        let transcript = await CacheProofEvaluator.run(
            queries: queries,
            maxTokens: exp.maxTokens ?? 128,
            thinkingPerTurn: exp.thinkingPerTurn
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
            "turns: \(transcript.visibleTurns.count) · topology: "
                + (transcript.hybridTopology ? "hybrid-SSM" : "full-attention"),
            "deltas: kvHits +\(transcript.kvPrefixHitsDelta) · kvMisses +\(transcript.kvPrefixMissesDelta) · "
                + "ssmHits +\(transcript.ssmCompanionHitsDelta) · ssmReDerives +\(transcript.ssmCompanionReDerivesDelta) · "
                + "diskHits +\(transcript.diskL2HitsDelta) · diskStores +\(transcript.diskL2StoresDelta)",
        ]
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
}
