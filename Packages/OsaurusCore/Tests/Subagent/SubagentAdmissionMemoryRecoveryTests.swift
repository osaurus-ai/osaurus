import Foundation
import Testing

@testable import OsaurusCore

@Suite("Admission freed-buffer recovery")
struct SubagentAdmissionMemoryRecoveryTests {
    private func facts(availableMiB: UInt64, budgetMiB: UInt64 = 11_264) -> SubagentBatchMemoryFacts {
        SubagentBatchMemoryFacts(
            canonicalModelKey: "same-resident-model",
            targetAlreadyResident: true,
            targetLoadFootprintBytes: 3 << 30,
            perActiveChildHeadroomBytes: 4 << 30,
            requestBoundedChildHeadroomBytes: 512 << 20,
            reclaimableBytes: availableMiB << 20,
            releasableParentBytes: 0,
            resolvedLoadBudgetBytes: budgetMiB << 20,
            osHeadroomBytes: 3 << 30
        )
    }

    private func plan(_ facts: SubagentBatchMemoryFacts?) -> SubagentBatchAdmissionPlan {
        SubagentBatchAdmissionPlanner.plan(.init(
            localJobCount: 1, remoteJobCount: 0, agentParallelLimit: 1,
            engineParallelLimit: 1, continuousBatchingEnabled: false,
            ramSafetyEnabled: true, failClosedWhenEstimateUnknown: true, memory: facts
        ))
    }

    @Test("first and sequential child remeasure actual memory after freed-buffer release")
    func sequentialRecovery() async throws {
        let admission = SubagentAdmission(pollNanoseconds: 1_000_000)
        for _ in 0..<2 {
            let before = facts(availableMiB: 3_328)
            let after = facts(availableMiB: 4_352)
            #expect(plan(before).localCapacity == 0)
            var samples = 0
            var trims = 0
            let recovered = await SubagentBatchAdmissionPlanner.memoryFactsAfterReclaimingIfNeeded(
                ramSafetyEnabled: true,
                sample: { samples += 1; return samples == 1 ? before : after },
                reclaim: { trims += 1; return true }
            )
            #expect(samples == 2)
            #expect(trims == 1)
            #expect(plan(recovered).localCapacity == 1)
            #expect(recovered == after)
            // Use the real reservation lifecycle, with a bounded timeout so
            // a failed red assertion cannot leave the test waiting forever.
            if plan(recovered).localCapacity > 0 {
                let reserved = await admission.reserveLocalInPlace(
                    modelKey: after.canonicalModelKey,
                    requestedSlots: 1,
                    slotCapacity: plan(recovered).localCapacity
                )
                #expect(reserved == .admitted(slots: 1))
                await admission.releaseLocalInPlace(modelKey: after.canonicalModelKey, slots: 1)
                #expect(await admission.snapshot().inPlace == 0)
            }
        }
    }

    @Test("busy allocator or ineffective release never invents memory or loops", arguments: [false, true])
    func stillUnsafe(trimmed: Bool) async {
        let unsafe = facts(availableMiB: 3_328)
        var samples = 0
        var trims = 0
        let result = await SubagentBatchAdmissionPlanner.memoryFactsAfterReclaimingIfNeeded(
            ramSafetyEnabled: true,
            sample: { samples += 1; return unsafe },
            reclaim: { trims += 1; return trimmed }
        )
        #expect(plan(result).verdict == .rejected(.insufficientMemory))
        #expect(trims == 1)
        #expect(samples == (trimmed ? 2 : 1))
    }

    @Test("safe, disabled, unknown and explicit-budget refusals do not trim")
    func noUnnecessaryTrim() async {
        for (enabled, memory) in [
            (true, Optional(facts(availableMiB: 4_352))),
            (false, Optional(facts(availableMiB: 3_328))),
            (true, nil),
            (true, Optional(facts(availableMiB: 3_328, budgetMiB: 3_200))),
        ] {
            var samples = 0
            var trims = 0
            let result = await SubagentBatchAdmissionPlanner.memoryFactsAfterReclaimingIfNeeded(
                ramSafetyEnabled: enabled,
                sample: { samples += 1; return memory },
                reclaim: { trims += 1; return true }
            )
            #expect(result == memory)
            #expect(samples == 1)
            #expect(trims == 0)
        }
    }

    @Test("a missing post-trim estimate fails closed instead of reusing old facts")
    func missingFreshEstimate() async {
        var samples = 0
        let result = await SubagentBatchAdmissionPlanner.memoryFactsAfterReclaimingIfNeeded(
            ramSafetyEnabled: true,
            sample: { samples += 1; return samples == 1 ? facts(availableMiB: 3_328) : nil },
            reclaim: { true }
        )
        #expect(samples == 2)
        #expect(result == nil)
        #expect(plan(result).verdict == .rejected(.unknownMemoryEstimate))
    }

    @Test("refusal diagnostics report the actual bounded cost and sampled inputs")
    func refusalDiagnostics() throws {
        let memory = facts(availableMiB: 3_328)
        let decision = plan(memory)
        #expect(decision.perActiveChildHeadroomBytes == 512 << 20)
        let payload = decision.memoryDiagnostics
        #expect(payload["per_child_bytes"] as? UInt64 == 512 << 20)
        #expect(payload["per_child_cap_bytes"] as? UInt64 == 4 << 30)
        #expect(payload["reclaimable_bytes"] as? UInt64 == memory.reclaimableBytes)
        #expect(payload["target_already_resident"] as? Bool == true)
        #expect(payload["ram_slots"] as? Int == 0)
        #expect(payload["limited_by"] as? [String] == ["memoryCapacity"])
        #expect(JSONSerialization.isValidJSONObject(payload))
    }

    @Test("cancellation before recovery does not trim or resample")
    func cancelledRecovery() async {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var samples = 0
            var trims = 0
            _ = await SubagentBatchAdmissionPlanner.memoryFactsAfterReclaimingIfNeeded(
                ramSafetyEnabled: true,
                sample: { samples += 1; return facts(availableMiB: 3_328) },
                reclaim: { trims += 1; return true }
            )
            #expect(samples == 1)
            #expect(trims == 0)
        }
        await task.value
    }
}
