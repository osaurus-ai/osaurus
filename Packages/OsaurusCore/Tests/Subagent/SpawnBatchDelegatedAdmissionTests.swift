//
//  SpawnBatchDelegatedAdmissionTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  Batched delegated admission: `spawn_batch` prices a wave through
//  `SubagentChildRequestEstimate.waveEnvelope` (the production combiner
//  used by `SpawnBatchTool`'s admission path) and the shared planner.
//  These pin the review blockers: a delegated job's ENFORCED position
//  ceiling must survive batching (dropping it silently reverts the wave
//  to cap pricing — the 16 GiB false rejection, reintroduced for
//  batches), heterogeneous jobs must never be under-priced by min-mixing
//  candidate fields, weights are charged once for a same-resident wave,
//  the largest child bound prices every slot, and continuous batching
//  OFF serializes subwaves while ON respects min(agent, engine, RAM).
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Batched delegated admission")
struct SpawnBatchDelegatedAdmissionTests {
    private let gib: UInt64 = 1 << 30
    private let mib: UInt64 = 1 << 20

    private func delegatedEstimate(ceiling: Int) -> SubagentChildRequestEstimate {
        SubagentChildRequestEstimate(
            seedCharacters: nil, maxOutputTokens: nil,
            enforcedPositionCeiling: ceiling)
    }

    // MARK: Wave envelope (the production combiner)

    /// Delegated jobs carry ONLY the enforced ceiling; the envelope must
    /// preserve it and price the wave at the largest per-child bound.
    @Test("delegated ceilings survive batching; max bound prices the wave")
    func delegatedCeilingsSurviveBatching() {
        let envelope = SubagentChildRequestEstimate.waveEnvelope(of: [
            delegatedEstimate(ceiling: 13_713),
            delegatedEstimate(ceiling: 24_000),
            delegatedEstimate(ceiling: 8_192),
        ])
        #expect(envelope?.enforcedPositionCeiling == 24_000)
        #expect(envelope?.boundedPositionBudget(policyCap: 65_536) == 24_000)
    }

    /// Heterogeneous jobs: one bare job bounded by seed+output, one
    /// delegated job bounded by a SMALLER ceiling. Field-mixing would take
    /// min(seed+output, ceiling) and under-price the bare job; the
    /// envelope must price the wave at the LARGER independent bound.
    @Test("heterogeneous wave prices at the larger independent bound")
    func heterogeneousWaveNeverUnderpriced() {
        let bare = SubagentChildRequestEstimate(
            seedCharacters: 60_000, maxOutputTokens: 10_000)
        // Independent bound: ceil(60,000×3/8)=22,500 + 10,000 = 32,500.
        #expect(bare.boundedPositionBudget(policyCap: nil) == 32_500)
        let delegated = delegatedEstimate(ceiling: 8_192)

        let envelope = SubagentChildRequestEstimate.waveEnvelope(of: [bare, delegated])
        #expect(envelope?.boundedPositionBudget(policyCap: 65_536) == 32_500)
    }

    /// Fail closed for the whole group: an empty batch, a job with no
    /// estimate, or a job whose estimate carries no valid bound all yield
    /// nil — the wave reverts to conservative cap pricing, never a
    /// partial bound.
    @Test("any unknown job fails the whole wave closed")
    func unknownJobFailsWaveClosed() {
        #expect(SubagentChildRequestEstimate.waveEnvelope(of: []) == nil)
        #expect(
            SubagentChildRequestEstimate.waveEnvelope(of: [
                delegatedEstimate(ceiling: 13_713), nil,
            ]) == nil)
        #expect(
            SubagentChildRequestEstimate.waveEnvelope(of: [
                delegatedEstimate(ceiling: 13_713),
                SubagentChildRequestEstimate(seedCharacters: nil, maxOutputTokens: nil),
            ]) == nil)
    }

    // MARK: Planner behavior for a bounded same-resident wave

    private func sameResidentFacts(boundedChildBytes: UInt64) -> SubagentBatchMemoryFacts {
        SubagentBatchMemoryFacts(
            canonicalModelKey: "osaurusai/gemma-4-e2b-it-qat",
            targetAlreadyResident: true,
            targetLoadFootprintBytes: 3 * gib,
            perActiveChildHeadroomBytes: 4 * gib,
            requestBoundedChildHeadroomBytes: boundedChildBytes,
            reclaimableBytes: 6 * gib,
            releasableParentBytes: 0,
            resolvedLoadBudgetBytes: 13 * gib,
            osHeadroomBytes: 3 * gib
        )
    }

    private func batchInput(
        jobs: Int,
        agentLimit: Int = 3,
        engineLimit: Int = 3,
        continuousBatching: Bool,
        facts: SubagentBatchMemoryFacts
    ) -> SubagentBatchAdmissionInput {
        SubagentBatchAdmissionInput(
            localJobCount: jobs,
            remoteJobCount: 0,
            agentParallelLimit: agentLimit,
            engineParallelLimit: engineLimit,
            continuousBatchingEnabled: continuousBatching,
            ramSafetyEnabled: true,
            failClosedWhenEstimateUnknown: true,
            memory: facts
        )
    }

    /// Same-resident wave of three delegated children: weights charged
    /// ONCE (zero incremental), every slot priced at the wave's bounded
    /// per-child state, and the projected peak = slots × per-child.
    @Test("same-resident wave charges weights once and per-child state per slot")
    func sameResidentWaveCharges() {
        let bounded = 600 * mib
        let plan = SubagentBatchAdmissionPlanner.plan(
            batchInput(
                jobs: 3, continuousBatching: true,
                facts: sameResidentFacts(boundedChildBytes: bounded)))
        #expect(plan.verdict == .admitted)
        #expect(plan.incrementalWeightChargeBytes == 0, "resident weights are never re-charged")
        #expect(plan.perActiveChildHeadroomBytes == bounded)
        // Residual 3 GiB / 600 MiB = 5 slots; capacity min(agent 3, engine 3, ram 5) = 3.
        #expect(plan.localParallelism == 3)
        #expect(plan.projectedIncrementalPeakBytes == UInt64(3) * bounded)
        #expect(plan.localSubwaveSizes == [3])
    }

    /// Continuous batching OFF: the engine admits ONE sequence at a time,
    /// so the wave serializes into one-slot subwaves regardless of RAM.
    @Test("continuous batching OFF serializes the wave into one-slot subwaves")
    func continuousBatchingOffSerializes() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            batchInput(
                jobs: 3, continuousBatching: false,
                facts: sameResidentFacts(boundedChildBytes: 600 * mib)))
        #expect(plan.verdict == .admitted)
        #expect(plan.engineSlots == 1)
        #expect(plan.localParallelism == 1)
        #expect(plan.localSubwaveSizes == [1, 1, 1])
    }

    /// Continuous batching ON: parallelism = min(agent limit, live engine
    /// capacity, RAM slots) — each dimension tested as the binding one.
    @Test("continuous batching ON takes min(agent, engine, RAM)")
    func continuousBatchingOnTakesMin() {
        // Engine-bound: engine window 2 < agent 3 < ram 5.
        let engineBound = SubagentBatchAdmissionPlanner.plan(
            batchInput(
                jobs: 3, engineLimit: 2, continuousBatching: true,
                facts: sameResidentFacts(boundedChildBytes: 600 * mib)))
        #expect(engineBound.localParallelism == 2)
        #expect(engineBound.localSubwaveSizes == [2, 1])

        // RAM-bound: residual 3 GiB / 1.4 GiB = 2 slots < agent/engine 3.
        let ramBound = SubagentBatchAdmissionPlanner.plan(
            batchInput(
                jobs: 3, continuousBatching: true,
                facts: sameResidentFacts(boundedChildBytes: 1_400 * mib)))
        #expect(ramBound.ramSlots == 2)
        #expect(ramBound.localParallelism == 2)
        #expect(ramBound.localSubwaveSizes == [2, 1])

        // Agent-bound: agent limit 1.
        let agentBound = SubagentBatchAdmissionPlanner.plan(
            batchInput(
                jobs: 1, agentLimit: 1, continuousBatching: true,
                facts: sameResidentFacts(boundedChildBytes: 600 * mib)))
        #expect(agentBound.localParallelism == 1)
    }

    /// A batched delegated wave on the 16 GiB facts: with the ceilings
    /// preserved (bounded pricing) the wave admits; with the envelope
    /// dropped (nil estimate → cap pricing) the SAME wave is refused —
    /// the exact regression the combiner fix prevents.
    @Test("dropping the delegated ceiling reintroduces the 16GiB batch refusal")
    func droppedCeilingReintroducesRefusal() {
        let priced = SubagentBatchAdmissionPlanner.plan(
            batchInput(
                jobs: 2, continuousBatching: true,
                facts: sameResidentFacts(boundedChildBytes: 600 * mib)))
        #expect(priced.verdict == .admitted)

        let unpriced = SubagentBatchAdmissionPlanner.plan(
            batchInput(
                jobs: 2, continuousBatching: true,
                facts: SubagentBatchMemoryFacts(
                    canonicalModelKey: "osaurusai/gemma-4-e2b-it-qat",
                    targetAlreadyResident: true,
                    targetLoadFootprintBytes: 3 * gib,
                    perActiveChildHeadroomBytes: 4 * gib,
                    requestBoundedChildHeadroomBytes: nil,
                    reclaimableBytes: 6 * gib,
                    releasableParentBytes: 0,
                    resolvedLoadBudgetBytes: 13 * gib,
                    osHeadroomBytes: 3 * gib
                )))
        guard case .rejected(let reason) = unpriced.verdict else {
            Issue.record("expected the cap-priced wave to reject, got \(unpriced.verdict)")
            return
        }
        #expect(reason == .insufficientMemory)
    }
}
