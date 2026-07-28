//
//  SubagentBatchAdmissionPlannerTests.swift
//  OsaurusCoreTests — Subagent framework
//

import Testing

@testable import OsaurusCore

@Suite("Subagent batch admission planner")
struct SubagentBatchAdmissionPlannerTests {
    private let gb: UInt64 = 1 << 30

    private func memory(
        resident: Bool = false,
        footprintGB: UInt64? = 10,
        childGB: UInt64? = 2,
        reclaimableGB: UInt64? = 25,
        releasableGB: UInt64 = 0,
        budgetGB: UInt64? = 20,
        osHeadroomGB: UInt64 = 3
    ) -> SubagentBatchMemoryFacts {
        SubagentBatchMemoryFacts(
            canonicalModelKey: "local/model",
            targetAlreadyResident: resident,
            targetLoadFootprintBytes: footprintGB.map { $0 * gb },
            perActiveChildHeadroomBytes: childGB.map { $0 * gb },
            reclaimableBytes: reclaimableGB.map { $0 * gb },
            releasableParentBytes: releasableGB * gb,
            resolvedLoadBudgetBytes: budgetGB.map { $0 * gb },
            osHeadroomBytes: osHeadroomGB * gb
        )
    }

    private func input(
        local: Int = 3,
        remote: Int = 0,
        agent: Int = 3,
        engine: Int = 3,
        continuousBatching: Bool = true,
        ramSafety: Bool = true,
        failClosed: Bool = true,
        memory: SubagentBatchMemoryFacts? = nil
    ) -> SubagentBatchAdmissionInput {
        SubagentBatchAdmissionInput(
            localJobCount: local,
            remoteJobCount: remote,
            agentParallelLimit: agent,
            engineParallelLimit: engine,
            continuousBatchingEnabled: continuousBatching,
            ramSafetyEnabled: ramSafety,
            failClosedWhenEstimateUnknown: failClosed,
            memory: memory
        )
    }

    @Test("same-model weights are charged once and child state per active slot")
    func chargesWeightsOnce() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(memory: memory())
        )

        #expect(plan.verdict == .admitted)
        #expect(plan.localParallelism == 3)
        #expect(plan.localSubwaveSizes == [3])
        #expect(plan.incrementalWeightChargeBytes == 10 * gb)
        #expect(plan.perActiveChildHeadroomBytes == 2 * gb)
        #expect(plan.projectedIncrementalPeakBytes == 16 * gb)
        #expect(plan.projectedModelWorkingSetBytes == 16 * gb)
        #expect(plan.ramSlots == 5)
    }

    @Test("resident target has no incremental weight charge but counts against total budget")
    func residentTargetBudgeting() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 2,
                agent: 2,
                engine: 2,
                memory: memory(
                    resident: true,
                    reclaimableGB: 15,
                    budgetGB: 16
                )
            )
        )

        #expect(plan.verdict == .admitted)
        #expect(plan.localParallelism == 2)
        #expect(plan.incrementalWeightChargeBytes == 0)
        #expect(plan.projectedIncrementalPeakBytes == 4 * gb)
        #expect(plan.projectedModelWorkingSetBytes == 14 * gb)
        #expect(plan.ramSlots == 3)
    }

    @Test("continuous batching off resolves local work into one-slot subwaves")
    func continuousBatchingOff() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                // Deliberately contradictory: the toggle must win even if a
                // stale caller still supplies a multi-slot engine setting.
                engine: 4,
                continuousBatching: false,
                ramSafety: false
            )
        )

        #expect(plan.verdict == .admitted)
        #expect(plan.engineSlots == 1)
        #expect(plan.localParallelism == 1)
        #expect(plan.localSubwaveSizes == [1, 1, 1])
        #expect(plan.limitingFactors.contains(.continuousBatchingDisabled))
        #expect(plan.limitingFactors.contains(.engineCapacity))
    }

    @Test("RAM capacity below engine capacity creates bounded local subwaves")
    func ramClampsLocalSubwaves() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                memory: memory(
                    reclaimableGB: 17,
                    budgetGB: 14
                )
            )
        )

        #expect(plan.verdict == .admitted)
        #expect(plan.ramSlots == 2)
        #expect(plan.localParallelism == 2)
        #expect(plan.localSubwaveSizes == [2, 1])
        #expect(plan.limitingFactors.contains(.memoryCapacity))
    }

    @Test("zero RAM capacity rejects before any local work is admitted")
    func zeroRAMRejects() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                memory: memory(
                    reclaimableGB: 12,
                    budgetGB: 20
                )
            )
        )

        #expect(plan.verdict == .rejected(.insufficientMemory))
        #expect(plan.localParallelism == 0)
        #expect(plan.remoteParallelism == 0)
        #expect(plan.ramSlots == 0)
    }

    @Test("strict RAM safety fails closed when authoritative estimates are unknown")
    func strictUnknownEstimateRejects() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(memory: nil)
        )

        #expect(plan.verdict == .rejected(.unknownMemoryEstimate))
        #expect(plan.limitingFactors.contains(.memoryEstimateUnavailable))
    }

    @Test("disabled RAM safety reports an unknown estimate without blocking")
    func disabledUnknownEstimateDoesNotClamp() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 2,
                agent: 2,
                engine: 2,
                ramSafety: false,
                memory: nil
            )
        )

        #expect(plan.verdict == .admitted)
        #expect(plan.localParallelism == 2)
        #expect(plan.ramSlots == nil)
        #expect(plan.limitingFactors.contains(.memoryEstimateUnavailable))
    }

    @Test("non-strict enabled policy reports an unknown estimate without inventing a cap")
    func nonStrictUnknownEstimateDoesNotClamp() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 2,
                agent: 2,
                engine: 2,
                failClosed: false,
                memory: nil
            )
        )

        #expect(plan.verdict == .admitted)
        #expect(plan.localParallelism == 2)
        #expect(plan.ramSlots == nil)
        #expect(plan.limitingFactors.contains(.memoryEstimateUnavailable))
    }

    @Test("remote jobs remain independent when local RAM admits only one slot")
    func remoteJobsRemainIndependent() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 3,
                remote: 2,
                agent: 5,
                engine: 3,
                memory: memory(
                    reclaimableGB: 15,
                    budgetGB: 12
                )
            )
        )

        #expect(plan.verdict == .admitted)
        #expect(plan.localParallelism == 1)
        #expect(plan.remoteParallelism == 2)
        #expect(plan.localSubwaveSizes == [1, 1, 1])
        #expect(plan.limitingFactors.contains(.memoryCapacity))
    }

    @Test("byte arithmetic saturates rather than wrapping")
    func byteArithmeticSaturates() {
        let facts = SubagentBatchMemoryFacts(
            canonicalModelKey: "huge/model",
            targetAlreadyResident: false,
            targetLoadFootprintBytes: .max,
            perActiveChildHeadroomBytes: .max,
            reclaimableBytes: .max,
            releasableParentBytes: .max,
            resolvedLoadBudgetBytes: nil,
            osHeadroomBytes: 0
        )
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 2,
                agent: 2,
                engine: 2,
                ramSafety: false,
                memory: facts
            )
        )

        #expect(plan.verdict == .admitted)
        #expect(plan.projectedIncrementalPeakBytes == UInt64.max)
        #expect(plan.projectedModelWorkingSetBytes == UInt64.max)
    }

    @Test("oversized batch is rejected instead of silently dropping jobs")
    func oversizedBatchRejects() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 2,
                remote: 2,
                agent: 3,
                ramSafety: false
            )
        )

        #expect(plan.verdict == .rejected(.batchExceedsAgentLimit))
        #expect(plan.limitingFactors == [.agentPolicy])
    }

    @Test("remote-only batch needs no local memory estimate")
    func remoteOnlyNeedsNoMemoryEstimate() {
        let plan = SubagentBatchAdmissionPlanner.plan(
            input(
                local: 0,
                remote: 3,
                agent: 3,
                engine: 1,
                continuousBatching: false,
                memory: nil
            )
        )

        #expect(plan.verdict == .admitted)
        #expect(plan.localParallelism == 0)
        #expect(plan.remoteParallelism == 3)
        #expect(plan.localSubwaveSizes.isEmpty)
        #expect(plan.limitingFactors.isEmpty)
    }
}
