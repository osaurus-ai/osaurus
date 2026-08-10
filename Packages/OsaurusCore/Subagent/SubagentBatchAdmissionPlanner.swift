//
//  SubagentBatchAdmissionPlanner.swift
//  OsaurusCore — Subagent framework
//
//  Pure capacity policy for one canonical local-model group plus any remote
//  jobs that may overlap it. This is deliberately not a scheduler:
//  `SpawnBatchTool` owns fan-out and vMLX `BatchEngine` owns inference.
//

import Foundation

enum SubagentBatchAdmissionRejection: String, Sendable, Equatable {
    case invalidParallelLimit
    case batchExceedsAgentLimit
    case unknownMemoryEstimate
    case insufficientMemory
}

enum SubagentBatchAdmissionVerdict: Sendable, Equatable {
    case admitted
    case rejected(SubagentBatchAdmissionRejection)
}

enum SubagentBatchLimitingFactor: String, Sendable, Hashable {
    case agentPolicy
    case continuousBatchingDisabled
    case engineCapacity
    case memoryCapacity
    case memoryEstimateUnavailable
}

/// Authoritative memory facts resolved by `ModelRuntime`.
///
/// `targetLoadFootprintBytes` is the model's effective load footprint, not
/// necessarily its raw on-disk shard total. `perActiveChildHeadroomBytes`
/// reuses ModelRuntime's architecture-aware KV/SSM/activation estimate.
struct SubagentBatchMemoryFacts: Sendable, Equatable {
    let canonicalModelKey: String
    let targetAlreadyResident: Bool
    let targetLoadFootprintBytes: UInt64?
    let perActiveChildHeadroomBytes: UInt64?
    let reclaimableBytes: UInt64?
    let releasableParentBytes: UInt64
    let resolvedLoadBudgetBytes: UInt64?
    let osHeadroomBytes: UInt64
}

struct SubagentBatchAdmissionInput: Sendable, Equatable {
    let localJobCount: Int
    let remoteJobCount: Int
    let agentParallelLimit: Int
    /// vMLX `maxConcurrentSequences`. The planner independently applies the
    /// Continuous Batching toggle so a stale or contradictory caller cannot
    /// accidentally admit concurrent local work while batching is disabled.
    let engineParallelLimit: Int
    let continuousBatchingEnabled: Bool
    let ramSafetyEnabled: Bool
    let failClosedWhenEstimateUnknown: Bool
    let memory: SubagentBatchMemoryFacts?
}

struct SubagentBatchAdmissionPlan: Sendable, Equatable {
    var verdict: SubagentBatchAdmissionVerdict
    /// Process-wide same-model sequence ceiling from agent policy, the active
    /// server BatchEngine setting, and RAM safety. Unlike
    /// `localParallelism`, this is not capped by this call's job count.
    var localCapacity: Int
    /// Width this specific call may schedule.
    var localParallelism: Int
    var remoteParallelism: Int
    var localSubwaveSizes: [Int]
    var engineSlots: Int
    var ramSlots: Int?
    var incrementalWeightChargeBytes: UInt64?
    var perActiveChildHeadroomBytes: UInt64?
    var projectedIncrementalPeakBytes: UInt64?
    var projectedModelWorkingSetBytes: UInt64?
    var limitingFactors: Set<SubagentBatchLimitingFactor>
    /// Atomic vMLX occupancy observed immediately before planning this wave.
    /// It is diagnostic context, never a reservation.
    var engineOccupancy: ModelBatchCapacitySnapshot? = nil
    /// True when no slot was nominally free (or earlier engine work was already
    /// queued), so this wave deliberately submits only one request and lets
    /// BatchEngine own the queue.
    var engineQueuedAtAdmission = false
}

enum SubagentBatchAdmissionPlanner {
    static func plan(_ input: SubagentBatchAdmissionInput) -> SubagentBatchAdmissionPlan {
        let localJobs = max(0, input.localJobCount)
        let remoteJobs = max(0, input.remoteJobCount)
        let requestedJobs = saturatingIntAdd(localJobs, remoteJobs)
        let engineSlots =
            input.continuousBatchingEnabled
            ? max(1, input.engineParallelLimit)
            : 1

        guard input.agentParallelLimit > 0 else {
            return rejected(
                .invalidParallelLimit,
                engineSlots: engineSlots
            )
        }
        guard requestedJobs <= input.agentParallelLimit else {
            return rejected(
                .batchExceedsAgentLimit,
                engineSlots: engineSlots,
                limitingFactors: [.agentPolicy]
            )
        }

        // A remote-only batch does not allocate a local model or KV state.
        guard localJobs > 0 else {
            return SubagentBatchAdmissionPlan(
                verdict: .admitted,
                localCapacity: 0,
                localParallelism: 0,
                remoteParallelism: remoteJobs,
                localSubwaveSizes: [],
                engineSlots: engineSlots,
                ramSlots: nil,
                incrementalWeightChargeBytes: 0,
                perActiveChildHeadroomBytes: nil,
                projectedIncrementalPeakBytes: 0,
                projectedModelWorkingSetBytes: 0,
                limitingFactors: []
            )
        }

        var limitingFactors: Set<SubagentBatchLimitingFactor> = []
        if !input.continuousBatchingEnabled, localJobs > 1 {
            limitingFactors.insert(.continuousBatchingDisabled)
        }
        if engineSlots < localJobs {
            limitingFactors.insert(.engineCapacity)
        }

        let memoryCapacity = resolveMemoryCapacity(input.memory)
        if memoryCapacity == nil {
            limitingFactors.insert(.memoryEstimateUnavailable)
            if input.ramSafetyEnabled, input.failClosedWhenEstimateUnknown {
                return rejected(
                    .unknownMemoryEstimate,
                    engineSlots: engineSlots,
                    limitingFactors: limitingFactors
                )
            }
        }

        let policyAndEngineCapacity = min(input.agentParallelLimit, engineSlots)
        let ramSlots = memoryCapacity?.slots
        let localCapacity: Int
        if input.ramSafetyEnabled, let ramSlots {
            localCapacity = min(policyAndEngineCapacity, ramSlots)
            if ramSlots < min(localJobs, policyAndEngineCapacity) {
                limitingFactors.insert(.memoryCapacity)
            }
        } else {
            localCapacity = policyAndEngineCapacity
        }

        guard localCapacity > 0 else {
            return rejected(
                .insufficientMemory,
                engineSlots: engineSlots,
                ramSlots: ramSlots,
                memory: input.memory,
                limitingFactors: limitingFactors.union([.memoryCapacity])
            )
        }
        let localSlots = min(localJobs, localCapacity)

        let perChild = input.memory?.perActiveChildHeadroomBytes
        let incrementalWeight = input.memory.flatMap { facts -> UInt64? in
            facts.targetAlreadyResident ? 0 : facts.targetLoadFootprintBytes
        }
        let activeChildCharge = perChild.map {
            saturatingMultiply($0, UInt64(localSlots))
        }
        let projectedIncrementalPeak =
            zipOptionals(incrementalWeight, activeChildCharge).map {
                saturatingAdd($0.0, $0.1)
            }
        let projectedModelWorkingSet =
            zipOptionals(input.memory?.targetLoadFootprintBytes, activeChildCharge)
            .map { saturatingAdd($0.0, $0.1) }

        return SubagentBatchAdmissionPlan(
            verdict: .admitted,
            localCapacity: localCapacity,
            localParallelism: localSlots,
            remoteParallelism: remoteJobs,
            localSubwaveSizes: subwaveSizes(jobCount: localJobs, slots: localSlots),
            engineSlots: engineSlots,
            ramSlots: ramSlots,
            incrementalWeightChargeBytes: incrementalWeight,
            perActiveChildHeadroomBytes: perChild,
            projectedIncrementalPeakBytes: projectedIncrementalPeak,
            projectedModelWorkingSetBytes: projectedModelWorkingSet,
            limitingFactors: limitingFactors
        )
    }

    private struct MemoryCapacity {
        let slots: Int
    }

    private static func resolveMemoryCapacity(
        _ facts: SubagentBatchMemoryFacts?
    ) -> MemoryCapacity? {
        guard let facts,
            let footprint = positive(facts.targetLoadFootprintBytes),
            let perChild = positive(facts.perActiveChildHeadroomBytes),
            let reclaimable = facts.reclaimableBytes
        else {
            return nil
        }

        let incrementalWeight = facts.targetAlreadyResident ? 0 : footprint
        let availableBeforeReserve = saturatingAdd(
            reclaimable,
            facts.releasableParentBytes
        )
        let availableFixedCharge = saturatingAdd(
            incrementalWeight,
            facts.osHeadroomBytes
        )
        let availableResidual = saturatingSubtract(
            availableBeforeReserve,
            availableFixedCharge
        )
        var slots = clampedSlotCount(availableResidual / perChild)

        // The resolved load budget is a total model working-set cap, so the
        // target footprint is counted once even when that model is resident.
        // The fixed OS reserve belongs to the reclaimable-memory calculation,
        // not this model-only budget.
        if let budget = facts.resolvedLoadBudgetBytes {
            let budgetResidual = saturatingSubtract(budget, footprint)
            slots = min(slots, clampedSlotCount(budgetResidual / perChild))
        }
        return MemoryCapacity(slots: slots)
    }

    private static func positive(_ value: UInt64?) -> UInt64? {
        guard let value, value > 0 else { return nil }
        return value
    }

    static func subwaveSizes(jobCount: Int, slots: Int) -> [Int] {
        guard jobCount > 0, slots > 0 else { return [] }
        var remaining = jobCount
        var result: [Int] = []
        while remaining > 0 {
            let count = min(remaining, slots)
            result.append(count)
            remaining -= count
        }
        return result
    }

    private static func rejected(
        _ reason: SubagentBatchAdmissionRejection,
        engineSlots: Int,
        ramSlots: Int? = nil,
        memory: SubagentBatchMemoryFacts? = nil,
        limitingFactors: Set<SubagentBatchLimitingFactor> = []
    ) -> SubagentBatchAdmissionPlan {
        SubagentBatchAdmissionPlan(
            verdict: .rejected(reason),
            localCapacity: 0,
            localParallelism: 0,
            remoteParallelism: 0,
            localSubwaveSizes: [],
            engineSlots: engineSlots,
            ramSlots: ramSlots,
            incrementalWeightChargeBytes: memory.flatMap { facts -> UInt64? in
                facts.targetAlreadyResident ? 0 : facts.targetLoadFootprintBytes
            },
            perActiveChildHeadroomBytes: memory?.perActiveChildHeadroomBytes,
            projectedIncrementalPeakBytes: nil,
            projectedModelWorkingSetBytes: nil,
            limitingFactors: limitingFactors
        )
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    private static func saturatingSubtract(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs >= rhs ? lhs - rhs : 0
    }

    private static func saturatingMultiply(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        let (value, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? .max : value
    }

    private static func saturatingIntAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (value, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? .max : value
    }

    private static func clampedSlotCount(_ value: UInt64) -> Int {
        value > UInt64(Int.max) ? Int.max : Int(value)
    }

    private static func zipOptionals<T, U>(_ lhs: T?, _ rhs: U?) -> (T, U)? {
        guard let lhs, let rhs else { return nil }
        return (lhs, rhs)
    }
}
