import Foundation
import Testing

@testable import OsaurusCore

@Suite("Warning-pressure delegation RAM opt-out")
struct SubagentWarningPressureOptOutTests {
    private func facts(
        pressure: SubagentMemoryPressure = .warning,
        resident: Bool = true,
        available: UInt64? = 3_290_628_096
    ) -> SubagentBatchMemoryFacts {
        .init(
            canonicalModelKey: "gemma-4-e2b-it-8bit",
            targetAlreadyResident: resident,
            targetLoadFootprintBytes: 5_899_232_198,
            perActiveChildHeadroomBytes: 1_014_497_280,
            requestBoundedChildHeadroomBytes: 1_014_497_280,
            reclaimableBytes: available,
            releasableParentBytes: 0,
            resolvedLoadBudgetBytes: 12_025_908_428,
            osHeadroomBytes: 3_221_225_472,
            memoryPressure: pressure,
            allocatorCacheAllowanceBytes: 1_474_808_049
        )
    }

    private func input(
        enabled: Bool,
        memory: SubagentBatchMemoryFacts?,
        jobs: Int = 1,
        agentLimit: Int = 2,
        engineLimit: Int = 2,
        batching: Bool = true
    ) -> SubagentBatchAdmissionInput {
        .init(
            localJobCount: jobs, remoteJobCount: 0,
            agentParallelLimit: agentLimit, engineParallelLimit: engineLimit,
            continuousBatchingEnabled: batching, ramSafetyEnabled: enabled,
            failClosedWhenEstimateUnknown: true, memory: memory
        )
    }

    @Test("reported warning sample fails the reserve, not a duplicate weight load")
    func reportedWarningRefusesWithSafetyOn() {
        let memory = facts()
        #expect(!memory.usesIncrementalResidentAdmission)
        #expect(memory.effectiveOSHeadroomBytes == 3_221_225_472)
        #expect(memory.reclaimableBytes! - memory.effectiveOSHeadroomBytes == 69_402_624)
        let plan = SubagentBatchAdmissionPlanner.plan(input(enabled: true, memory: memory))
        #expect(plan.verdict == .rejected(.insufficientMemory))
        #expect(plan.ramSlots == 0)
        #expect(plan.localCapacity == 0)
        #expect(plan.incrementalWeightChargeBytes == 0)
        #expect(plan.memoryDiagnostics["ram_safety_enabled"] as? Bool == true)
    }

    @Test("OFF bypasses identical warning facts, critical/unknown pressure, cold and unknown estimates")
    func optOutDoesNotApplyMemoryVeto() {
        let samples: [SubagentBatchMemoryFacts?] = [
            facts(), facts(pressure: .critical), facts(pressure: .unknown),
            facts(resident: false), facts(available: 0), facts(available: nil), nil,
        ]
        for memory in samples {
            let plan = SubagentBatchAdmissionPlanner.plan(input(enabled: false, memory: memory))
            #expect(plan.verdict == .admitted)
            #expect(plan.localCapacity == 2)
            #expect(plan.localParallelism == 1)
            #expect(!plan.limitingFactors.contains(.memoryCapacity))
            #expect(plan.memoryDiagnostics["ram_safety_enabled"] as? Bool == false)
        }
    }

    @Test("drain and a fresh identical warning sample cannot repair a policy shortfall")
    func repeatedWarningIsNotAnUnreleasedReservation() async {
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        for enabled in [true, false, false, true] {
            var samples = 0
            var trims = 0
            var waits = 0
            let memory = await SubagentBatchAdmissionPlanner.memoryFactsAfterReclaimingIfNeeded(
                ramSafetyEnabled: enabled,
                sample: { samples += 1; return facts() },
                reclaim: { trims += 1; return true },
                waitForPostReclaimSample: { waits += 1 }
            )
            let plan = SubagentBatchAdmissionPlanner.plan(input(enabled: enabled, memory: memory))
            #expect(plan.localCapacity == (enabled ? 0 : 2))
            #expect(samples == (enabled ? 2 : 1))
            #expect(trims == (enabled ? 1 : 0))
            #expect(waits == (enabled ? 1 : 0))
            if !enabled {
                let reserved = await admission.reserveLocalInPlace(
                    modelKey: "gemma-4-e2b-it-8bit", requestedSlots: 2,
                    slotCapacity: plan.localCapacity, timeoutSeconds: 0.1
                )
                guard case .admitted(let slots) = reserved else {
                    Issue.record("OFF must admit after the preceding refusal/released wave")
                    return
                }
                #expect(slots == 2)
                await admission.releaseLocalInPlace(modelKey: "gemma-4-e2b-it-8bit", slots: slots)
            }
            let snapshot = await admission.snapshot()
            #expect(snapshot.inPlace == 0)
            #expect(snapshot.exclusive == 0)
        }
    }

    @Test("OFF never reclaims or waits for a later memory sample")
    func optOutSkipsRecovery() async {
        var samples = 0
        var trims = 0
        var waits = 0
        let memory = facts()
        let result = await SubagentBatchAdmissionPlanner.memoryFactsAfterReclaimingIfNeeded(
            ramSafetyEnabled: false,
            sample: { samples += 1; return memory },
            reclaim: { trims += 1; return true },
            waitForPostReclaimSample: { waits += 1 }
        )
        #expect(result == memory)
        #expect(samples == 1)
        #expect(trims == 0)
        #expect(waits == 0)
    }

    @Test("OFF preserves explicit fan-out and engine serialization")
    func optOutDoesNotDisableNonMemoryLimits() {
        let overLimit = SubagentBatchAdmissionPlanner.plan(
            input(enabled: false, memory: facts(), jobs: 3, agentLimit: 2)
        )
        #expect(overLimit.verdict == .rejected(.batchExceedsAgentLimit))
        for batching in [true, false] {
            let plan = SubagentBatchAdmissionPlanner.plan(
                input(enabled: false, memory: facts(), jobs: 2, engineLimit: 1, batching: batching)
            )
            #expect(plan.verdict == .admitted)
            #expect(plan.localSubwaveSizes == [1, 1])
        }
    }
}
