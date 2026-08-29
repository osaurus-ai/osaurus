//
//  SubagentAdmissionSettingsMatrixTests.swift
//  OsaurusCoreTests — Subagent framework
//
//  The full settings matrix at the planner layer:
//  RAM Safety on/off × residency shape × safe/unsafe memory.
//
//  Residency shapes map the user-facing toggles onto planner facts:
//  - SAME-RESIDENT model: `targetAlreadyResident = true`,
//    `releasableParentBytes = 0` (one weight graph; nothing unloads).
//  - DIFFERENT model + Local Handoff ON: `targetAlreadyResident = false`,
//    `releasableParentBytes = parent footprint` (parent unloads, its
//    memory funds the child load).
//  - DIFFERENT model + Coexistence (Keep Chat Model Loaded) ON:
//    `targetAlreadyResident = false`, `releasableParentBytes = 0` — BOTH
//    models must fit; rejection happens BEFORE any eviction.
//
//  All scenarios model the 16 GiB report's machine scale (3 GiB OS
//  reserve). Every row states its arithmetic inline.
//

import Foundation
import Testing

@testable import OsaurusCore

@Suite("Spawn admission settings matrix")
struct SubagentAdmissionSettingsMatrixTests {
    private let gib: UInt64 = 1 << 30
    private let mib: UInt64 = 1 << 20

    private func facts(
        resident: Bool,
        targetFootprint: UInt64,
        childBytes: UInt64,
        reclaimable: UInt64,
        releasableParent: UInt64
    ) -> SubagentBatchMemoryFacts {
        SubagentBatchMemoryFacts(
            canonicalModelKey: "matrix/model",
            targetAlreadyResident: resident,
            targetLoadFootprintBytes: targetFootprint,
            perActiveChildHeadroomBytes: childBytes,
            requestBoundedChildHeadroomBytes: nil,
            reclaimableBytes: reclaimable,
            releasableParentBytes: releasableParent,
            resolvedLoadBudgetBytes: 13 * gib,
            osHeadroomBytes: 3 * gib
        )
    }

    private func input(
        ramSafety: Bool,
        memory: SubagentBatchMemoryFacts?
    ) -> SubagentBatchAdmissionInput {
        SubagentBatchAdmissionInput(
            localJobCount: 1,
            remoteJobCount: 0,
            agentParallelLimit: 3,
            engineParallelLimit: 3,
            continuousBatchingEnabled: true,
            ramSafetyEnabled: ramSafety,
            failClosedWhenEstimateUnknown: true,
            memory: memory
        )
    }

    // MARK: RAM Safety ON

    /// Same-resident, safe: residual = 6 − (0 + 3) = 3 GiB; child 500 MiB
    /// → admitted, weights charged once.
    @Test("safety ON · same-resident · safe → admitted")
    func safetyOnSameResidentSafe() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                ramSafety: true,
                memory: facts(
                    resident: true, targetFootprint: 3 * gib,
                    childBytes: 500 * mib, reclaimable: 6 * gib,
                    releasableParent: 0)))
        #expect(plan.verdict == .admitted)
        #expect(plan.incrementalWeightChargeBytes == 0)
    }

    /// Same-resident, unsafe: residual 3 GiB; child 4 GiB → rejected.
    @Test("safety ON · same-resident · unsafe → rejected")
    func safetyOnSameResidentUnsafe() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                ramSafety: true,
                memory: facts(
                    resident: true, targetFootprint: 3 * gib,
                    childBytes: 4 * gib, reclaimable: 6 * gib,
                    releasableParent: 0)))
        guard case .rejected(let reason) = plan.verdict else {
            Issue.record("expected rejection, got \(plan.verdict)")
            return
        }
        #expect(reason == .insufficientMemory)
    }

    /// Different model + handoff, safe: available = 4 + 6 (parent
    /// releases) = 10; fixed = 5 (load) + 3 (reserve) = 8; residual 2 GiB;
    /// child 500 MiB → admitted, and the child load IS charged.
    @Test("safety ON · handoff · safe → admitted with weight charge")
    func safetyOnHandoffSafe() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                ramSafety: true,
                memory: facts(
                    resident: false, targetFootprint: 5 * gib,
                    childBytes: 500 * mib, reclaimable: 4 * gib,
                    releasableParent: 6 * gib)))
        #expect(plan.verdict == .admitted)
        #expect(plan.incrementalWeightChargeBytes == 5 * gib)
    }

    /// Different model + handoff, unsafe: available 10; fixed = 8 + 3 =
    /// 11 → negative residual → rejected even though the parent releases.
    @Test("safety ON · handoff · unsafe → rejected")
    func safetyOnHandoffUnsafe() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                ramSafety: true,
                memory: facts(
                    resident: false, targetFootprint: 8 * gib,
                    childBytes: 500 * mib, reclaimable: 4 * gib,
                    releasableParent: 6 * gib)))
        guard case .rejected(let reason) = plan.verdict else {
            Issue.record("expected rejection, got \(plan.verdict)")
            return
        }
        #expect(reason == .insufficientMemory)
    }

    /// Different model + coexistence, safe: parent releases NOTHING;
    /// available = 10 (reclaimable alone); fixed = 5 + 3 = 8; residual
    /// 2 GiB → both models fit → admitted.
    @Test("safety ON · coexistence · safe → admitted, parent stays")
    func safetyOnCoexistenceSafe() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                ramSafety: true,
                memory: facts(
                    resident: false, targetFootprint: 5 * gib,
                    childBytes: 500 * mib, reclaimable: 10 * gib,
                    releasableParent: 0)))
        #expect(plan.verdict == .admitted)
        #expect(plan.incrementalWeightChargeBytes == 5 * gib)
    }

    /// Different model + coexistence, unsafe: available = 6 only; fixed =
    /// 5 + 3 = 8 → rejected BEFORE any eviction — the reject-before-evict
    /// contract (the parent is never sacrificed to admit the child).
    @Test("safety ON · coexistence · unsafe → rejected before eviction")
    func safetyOnCoexistenceUnsafe() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                ramSafety: true,
                memory: facts(
                    resident: false, targetFootprint: 5 * gib,
                    childBytes: 500 * mib, reclaimable: 6 * gib,
                    releasableParent: 0)))
        guard case .rejected(let reason) = plan.verdict else {
            Issue.record("expected rejection, got \(plan.verdict)")
            return
        }
        #expect(reason == .insufficientMemory)
    }

    /// Unknown estimate with safety ON fails CLOSED.
    @Test("safety ON · unknown estimate → rejected (fail closed)")
    func safetyOnUnknownEstimate() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(ramSafety: true, memory: nil))
        guard case .rejected(let reason) = plan.verdict else {
            Issue.record("expected rejection, got \(plan.verdict)")
            return
        }
        #expect(reason == .unknownMemoryEstimate)
    }

    // MARK: RAM Safety OFF

    /// Safety OFF admits every memory shape above — including the unsafe
    /// ones — because the user disabled the gate; capacity is then policy
    /// and engine only. The planner must not smuggle the RAM veto back in.
    @Test("safety OFF admits all residency shapes regardless of memory")
    func safetyOffAdmitsAllShapes() {
        let shapes: [SubagentBatchMemoryFacts?] = [
            facts(
                resident: true, targetFootprint: 3 * gib,
                childBytes: 4 * gib, reclaimable: 6 * gib, releasableParent: 0),
            facts(
                resident: false, targetFootprint: 8 * gib,
                childBytes: 500 * mib, reclaimable: 4 * gib, releasableParent: 6 * gib),
            facts(
                resident: false, targetFootprint: 5 * gib,
                childBytes: 500 * mib, reclaimable: 6 * gib, releasableParent: 0),
            nil,  // even an unknown estimate cannot veto with safety off
        ]
        for shape in shapes {
            let plan = SubagentBatchAdmissionPlanner.plan(
                input(ramSafety: false, memory: shape))
            #expect(plan.verdict == .admitted, "safety OFF must not veto: \(String(describing: shape))")
            #expect(plan.localParallelism == 1)
        }
    }
}
