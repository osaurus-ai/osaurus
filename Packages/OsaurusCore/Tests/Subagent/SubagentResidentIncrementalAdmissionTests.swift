import Foundation
import Testing

@testable import OsaurusCore

@Suite("Resident incremental RAM admission")
struct SubagentResidentIncrementalAdmissionTests {
    private let child: UInt64 = 536_870_912
    private let reporterAvailable: UInt64 = 2_442_035_200

    private func facts(
        available: UInt64? = 2_442_035_200,
        resident: Bool = true,
        pressure: SubagentMemoryPressure = .normal,
        bounded: Bool = true,
        budget: UInt64? = 12_025_908_428
    ) -> SubagentBatchMemoryFacts {
        .init(
            canonicalModelKey: "gemma-4-e2b-it-8bit",
            targetAlreadyResident: resident,
            targetLoadFootprintBytes: 5_899_232_198,
            perActiveChildHeadroomBytes: 6_055_526_640,
            requestBoundedChildHeadroomBytes: bounded ? child : nil,
            reclaimableBytes: available,
            releasableParentBytes: 0,
            resolvedLoadBudgetBytes: budget,
            osHeadroomBytes: 3_221_225_472,
            memoryPressure: pressure
        )
    }

    private func plan(_ facts: SubagentBatchMemoryFacts, jobs: Int = 1,
                      ceiling: Int = 1, ramSafety: Bool = true) -> SubagentBatchAdmissionPlan {
        SubagentBatchAdmissionPlanner.plan(.init(
            localJobCount: jobs, remoteJobCount: 0, agentParallelLimit: ceiling,
            engineParallelLimit: ceiling, continuousBatchingEnabled: true,
            ramSafetyEnabled: ramSafety, failClosedWhenEstimateUnknown: true, memory: facts
        ))
    }

    @Test("three singles then sequential children reuse the resident model at the reporter byte count")
    func reporterBytesWithNormalPressure() async {
        // The reporter supplied bytes, not a kernel pressure level. Test the
        // normal and unknown-pressure arms separately instead of inventing it.
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        for available: UInt64 in [3_758_096_384, 3_758_096_384, 3_758_096_384,
                                  reporterAvailable, reporterAvailable] {
            let decision = plan(facts(available: available))
            #expect(decision.localCapacity == 1)
            #expect(decision.incrementalWeightChargeBytes == 0)
            #expect(decision.perActiveChildHeadroomBytes == child)
            #expect(decision.memoryDiagnostics["os_reserve_bytes"] as? UInt64 == 0)
            if decision.localCapacity > 0 {
                #expect(await admission.reserveLocalInPlace(
                    modelKey: "gemma-4-e2b-it-8bit", requestedSlots: 1,
                    slotCapacity: decision.localCapacity, timeoutSeconds: 0.05
                ) == .admitted(slots: 1))
                await admission.releaseLocalInPlace(modelKey: "gemma-4-e2b-it-8bit", slots: 1)
            }
            #expect(await admission.snapshot().inPlace == 0)
        }
    }

    @Test("resident reuse still pays every child's state and respects engine width")
    func everyChildIsPriced() {
        let decision = plan(facts(available: 2 * child - 1), jobs: 3, ceiling: 3)
        #expect(decision.ramSlots == 1)
        #expect(decision.localSubwaveSizes == [1, 1, 1])
        let two = plan(facts(available: 2 * child), jobs: 3, ceiling: 3)
        #expect(two.ramSlots == 2)
        #expect(two.localSubwaveSizes == [2, 1])
        #expect(plan(facts(), jobs: 1, ceiling: 1).localCapacity == 1)
    }

    @Test("insufficient bytes, unknown samples, model budgets and cold loads still refuse")
    func unsafeRequestsStillRefuse() {
        for sample in [facts(available: child - 1), facts(available: nil),
                       facts(budget: 5_899_232_198 + child - 1), facts(resident: false),
                       facts(bounded: false), facts(budget: nil)] {
            #expect(plan(sample).localCapacity == 0)
        }
        #expect(plan(facts(available: child)).localCapacity == 1)
    }

    @Test("kernel pressure decoding never defaults a failed or unknown reading to normal")
    func pressureDecoding() {
        #expect(SubagentMemoryPressure.fromKernelLevel(1) == .normal)
        #expect(SubagentMemoryPressure.fromKernelLevel(2) == .warning)
        #expect(SubagentMemoryPressure.fromKernelLevel(4) == .critical)
        for value: Int32 in [0, -1, 3, 5, Int32.max] {
            #expect(SubagentMemoryPressure.fromKernelLevel(value) == .unknown)
        }
    }

    @Test("unknown or warning pressure preserves the conservative reserve; critical refuses")
    func pressureIsNotAssumed() {
        for pressure: SubagentMemoryPressure in [.unknown, .warning, .critical] {
            #expect(plan(facts(pressure: pressure)).localCapacity == 0)
        }
        #expect(plan(facts(available: 16 << 30, pressure: .critical)).localCapacity == 0)
        #expect(plan(facts(pressure: .critical), ramSafety: false).localCapacity == 1)
    }

    @Test("recovery must resample pressure as well as bytes")
    func recoveryRemeasuresPressure() async {
        var samples = 0
        var trims = 0
        let result = await SubagentBatchAdmissionPlanner.memoryFactsAfterReclaimingIfNeeded(
            ramSafetyEnabled: true,
            sample: {
                samples += 1
                return facts(pressure: samples == 1 ? .warning : .normal)
            },
            reclaim: { trims += 1; return true },
            waitForPostReclaimSample: {}
        )
        #expect(samples == 2)
        #expect(trims == 1)
        #expect(result.map { plan($0).localCapacity } == 1)
    }
}
