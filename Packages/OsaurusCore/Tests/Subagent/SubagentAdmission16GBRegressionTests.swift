//
//  SubagentAdmission16GBRegressionTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Deterministic regressions for the 16 GB same-resident-model spawn
//  rejection (osaurus 0.24.1 report): admission priced every child at the
//  model-wide KV retention envelope, so a single bounded 2,048-token
//  delegation against the ALREADY-RESIDENT parent model computed
//  ramSlots == 0 even though its actual incremental state fits easily.
//  The fix prices a child from its bounded request (seed + max output,
//  clamped to policy) when the request is known, and never above the
//  conservative cap-priced estimate. RAM safety is ON in every scenario
//  here — nothing bypasses the gate; genuinely unsafe children still fail.
//
//  Scenario constants model the report: 16 GiB physical memory, parent and
//  child use the identical canonical Gemma E2B bundle (~3 GiB effective
//  footprint), RAM safety on, handoff on, coexistence off. With the E2B
//  architecture and a 64K retention cap the cap-priced per-child estimate
//  lands in the multi-GiB range; the bounded 2K-output estimate is a few
//  hundred MiB. Free memory after the resident parent is ~6 GiB and the
//  fixed OS reserve is 3 GiB.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("16 GiB same-resident-model spawn admission")
struct SubagentAdmission16GBRegressionTests {
    private let gib: UInt64 = 1 << 30
    private let mib: UInt64 = 1 << 20

    /// Facts shaped like the 16 GiB report: Gemma E2B resident, ~6 GiB
    /// reclaimable, 3 GiB OS reserve, no releasable parent (same-model
    /// spawns run in place and unload nothing).
    private func sixteenGBFacts(
        capPricedChildBytes: UInt64,
        boundedChildBytes: UInt64?
    ) -> SubagentBatchMemoryFacts {
        SubagentBatchMemoryFacts(
            canonicalModelKey: "osaurusai/gemma-4-e2b-it-qat",
            targetAlreadyResident: true,
            targetLoadFootprintBytes: 3 * gib,
            perActiveChildHeadroomBytes: capPricedChildBytes,
            requestBoundedChildHeadroomBytes: boundedChildBytes,
            reclaimableBytes: 6 * gib,
            releasableParentBytes: 0,
            resolvedLoadBudgetBytes: 13 * gib,
            osHeadroomBytes: 3 * gib
        )
    }

    private func input(
        local: Int,
        memory: SubagentBatchMemoryFacts
    ) -> SubagentBatchAdmissionInput {
        SubagentBatchAdmissionInput(
            localJobCount: local,
            remoteJobCount: 0,
            agentParallelLimit: 3,
            engineParallelLimit: 3,
            continuousBatchingEnabled: true,
            ramSafetyEnabled: true,
            failClosedWhenEstimateUnknown: true,
            memory: memory
        )
    }

    /// The REPORTED failure, unfixed shape: cap-priced 4 GiB per child
    /// against (6 GiB reclaimable − 3 GiB OS reserve) = 3 GiB residual →
    /// zero slots → the exact rejection, even for ONE child.
    @Test("cap-priced child yields ramSlots=0 on 16GiB — the reported defect shape")
    func capPricedChildIsRejected() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 1,
                memory: sixteenGBFacts(
                    capPricedChildBytes: 4 * gib,
                    boundedChildBytes: nil
                )
            )
        )
        guard case .rejected(let reason) = plan.verdict else {
            Issue.record("expected rejection, got \(plan.verdict)")
            return
        }
        #expect(reason == .insufficientMemory)
        #expect(plan.ramSlots == 0)
    }

    /// The fix: the same machine and model, but the child is priced from
    /// its bounded request (2,048-token output ⇒ a few hundred MiB) — one
    /// child is admitted.
    @Test("request-bounded single child is admitted on 16GiB")
    func boundedSingleChildAdmitted() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 1,
                memory: sixteenGBFacts(
                    capPricedChildBytes: 4 * gib,
                    boundedChildBytes: 400 * mib
                )
            )
        )
        #expect(plan.verdict == .admitted)
        #expect(plan.localParallelism == 1)
        #expect(plan.incrementalWeightChargeBytes == 0, "resident weights charged once, not twice")
        #expect(plan.perActiveChildHeadroomBytes == 400 * mib)
    }

    /// Two/three bounded children split into safe waves when the residual
    /// only affords part of the batch at once.
    @Test("two and three bounded children split into safe waves")
    func boundedWavesSplitSafely() {
        // Residual = 6 − 3 = 3 GiB; at 1.4 GiB per bounded child → 2 slots.
        let facts = sixteenGBFacts(
            capPricedChildBytes: 4 * gib,
            boundedChildBytes: 1400 * mib
        )
        let two = SubagentBatchAdmissionPlanner.plan(input(local: 2, memory: facts))
        #expect(two.verdict == .admitted)
        #expect(two.localParallelism == 2)
        #expect(two.localSubwaveSizes == [2])

        let three = SubagentBatchAdmissionPlanner.plan(input(local: 3, memory: facts))
        #expect(three.verdict == .admitted)
        #expect(three.localParallelism == 2)
        #expect(three.localSubwaveSizes == [2, 1], "third child waits for a free slot")
    }

    /// A genuinely unsafe single child still fails closed: even the
    /// bounded request cannot fit the residual.
    @Test("genuinely insufficient bounded child remains rejected")
    func genuinelyInsufficientStillRejected() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 1,
                memory: sixteenGBFacts(
                    capPricedChildBytes: 6 * gib,
                    boundedChildBytes: 5 * gib
                )
            )
        )
        guard case .rejected(let reason) = plan.verdict else {
            Issue.record("expected rejection, got \(plan.verdict)")
            return
        }
        #expect(reason == .insufficientMemory)
    }

    /// A bounded estimate can only SHRINK the charge: if a caller ever
    /// supplies a bounded value above the cap-priced envelope, the
    /// conservative value wins.
    @Test("bounded estimate never exceeds the cap-priced envelope")
    func boundedEstimateClampedToCap() {
        let facts = sixteenGBFacts(
            capPricedChildBytes: 2 * gib,
            boundedChildBytes: 10 * gib
        )
        #expect(facts.effectiveChildHeadroomBytes == 2 * gib)
    }

    /// Identical normalized model keys receive identical admission
    /// decisions — SysAdmin vs Research is a label, not a memory class.
    @Test("identical canonical model facts produce identical decisions")
    func identicalFactsIdenticalDecisions() {
        let facts = sixteenGBFacts(
            capPricedChildBytes: 4 * gib,
            boundedChildBytes: 400 * mib
        )
        let sysAdmin = SubagentBatchAdmissionPlanner.plan(input(local: 1, memory: facts))
        let research = SubagentBatchAdmissionPlanner.plan(input(local: 1, memory: facts))
        #expect(sysAdmin == research)
    }

    /// The bounded-position budget math itself: a 2,048-output child with a
    /// short instruction stays at the 4,096 floor, far below a 64K policy
    /// cap; a huge seed clamps to the cap, never above it; token math
    /// rounds UP (ceiling), never truncates.
    @Test("bounded position budget: floor, clamp, ceiling")
    func boundedPositionBudgetMath() {
        let small = SubagentChildRequestEstimate(
            seedCharacters: 800, maxOutputTokens: 2048)
        #expect(small.boundedPositionBudget(policyCap: 65536) == 4096)

        let huge = SubagentChildRequestEstimate(
            seedCharacters: 1_000_000, maxOutputTokens: 2048)
        #expect(huge.boundedPositionBudget(policyCap: 65536) == 65536)

        // Ceiling: 13,001 chars × 3 = 39,003; /8 truncating would give
        // 4,875 — the estimator must round UP to 4,876.
        let ceiling = SubagentChildRequestEstimate(
            seedCharacters: 13_001, maxOutputTokens: 10_000)
        #expect(ceiling.boundedPositionBudget(policyCap: 65536) == 4876 + 10_000)
    }

    /// An INCOMPLETE contract is not a bound: a missing seed OR a missing
    /// (or non-positive) output ceiling must fall back to conservative
    /// cap pricing, never a partial guess.
    @Test("incomplete request bounds fall back to conservative pricing")
    func incompleteBoundsFallBack() {
        #expect(
            SubagentChildRequestEstimate(seedCharacters: nil, maxOutputTokens: 2048)
                .boundedPositionBudget(policyCap: 65536) == nil)
        #expect(
            SubagentChildRequestEstimate(seedCharacters: 800, maxOutputTokens: nil)
                .boundedPositionBudget(policyCap: 65536) == nil)
        #expect(
            SubagentChildRequestEstimate(seedCharacters: 800, maxOutputTokens: 0)
                .boundedPositionBudget(policyCap: 65536) == nil)
        #expect(
            SubagentChildRequestEstimate(seedCharacters: nil, maxOutputTokens: nil)
                .boundedPositionBudget(policyCap: 65536) == nil)
    }

    /// CAUSAL: a delegated agent target runs the TARGET agent's chat
    /// contract (`runDelegated` ignores launcher budgets), so the launcher's
    /// 2,048-token display limit must NOT price the child — the estimator
    /// returns nil and admission keeps the conservative cap price. A
    /// launcher limit of 2K pricing a 16K-capable delegated chat would be
    /// an under-priced, fail-open admission.
    @Test("delegated agent target is never priced by launcher budgets")
    func delegatedAgentTargetNotPricedByLauncher() {
        let delegated = TextSubagentKind(agentID: UUID(), input: "audit the disk")
        #expect(delegated.admissionRequestEstimate() == nil)
    }

    /// CAUSAL: the bare `spawn_model` path IS governed by launcher budgets
    /// (per-generation `maxDelegateTokens` × at most `maxDelegateTurns`
    /// iterations, no tool access) — it produces a bounded estimate whose
    /// output ceiling reflects turns × per-turn, not a single turn.
    @Test("bare model target produces a turns-aware bounded estimate")
    func bareModelTargetBoundedEstimate() {
        let bare = TextSubagentKind(model: "some/model", input: "summarize this")
        let estimate = bare.admissionRequestEstimate()
        #expect(estimate != nil)
        #expect(estimate?.seedCharacters == "summarize this".count)
        // Defaults: maxDelegateTokens 2048 × maxDelegateTurns 2.
        #expect(estimate?.maxOutputTokens == 2048 * 2)
    }

    /// CAUSAL: a longer seed (system prompt + schemas + instruction all
    /// arrive as seed characters) raises the priced bound monotonically —
    /// context the child must hold is context admission must charge.
    @Test("larger seed raises the priced bound")
    func largerSeedRaisesBound() {
        let short = SubagentChildRequestEstimate(
            seedCharacters: 1_000, maxOutputTokens: 4_096)
        let long = SubagentChildRequestEstimate(
            seedCharacters: 60_000, maxOutputTokens: 4_096)
        let shortBudget = short.boundedPositionBudget(policyCap: 65536)!
        let longBudget = long.boundedPositionBudget(policyCap: 65536)!
        #expect(longBudget > shortBudget)
        // 60,000 chars → ceil(60000×3/8)=22,500 tokens + 4,096 = 26,596.
        #expect(longBudget == 22_500 + 4_096)
    }
}
