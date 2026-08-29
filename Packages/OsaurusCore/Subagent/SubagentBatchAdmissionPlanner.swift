//
//  SubagentBatchAdmissionPlanner.swift
//  OsaurusCore — Subagent framework
//
//  Pure capacity policy for one canonical local-model group plus any remote
//  jobs that may overlap it. This is deliberately not a scheduler:
//  `SpawnBatchTool` owns fan-out and vMLX `BatchEngine` owns inference.
//

import Foundation
import os

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

/// What a specific delegation will actually ask the child to hold: the
/// seed/input size and the configured output ceiling. Used to price the
/// child's incremental KV/SSM state from the BOUNDED request instead of the
/// model-wide retention cap. Characters are converted at the repo-standard
/// chars/4 estimate with a 1.5× safety factor plus a 1024-token margin for
/// the child's system prompt and template overhead — conservative, but not
/// "the whole 64K window".
public struct SubagentChildRequestEstimate: Sendable, Equatable {
    public let seedCharacters: Int?
    public let maxOutputTokens: Int?
    /// A position ceiling the child's execution path ENFORCES outright —
    /// for a delegated chat session, the target agent's resolved context
    /// window (`AgentLoopBudget.resolveContextWindow`: bundle window ∩ the
    /// user's context-length cap), which the loop's budget manager trims
    /// history to on every request. Unlike seed/output, this bound holds
    /// even when tool results grow the transcript, because trimming applies
    /// to the whole outbound context.
    public let enforcedPositionCeiling: Int?

    public init(
        seedCharacters: Int?,
        maxOutputTokens: Int?,
        enforcedPositionCeiling: Int? = nil
    ) {
        self.seedCharacters = seedCharacters
        self.maxOutputTokens = maxOutputTokens
        self.enforcedPositionCeiling = enforcedPositionCeiling
    }

    /// nil when nothing bounded is known (fail back to the cap-priced
    /// conservative estimate). Token math rounds UP (ceiling) — a
    /// truncating estimate would shave the bound in the unsafe direction.
    /// Two independent bounds can contribute and the TIGHTER one wins:
    /// seed + output (requires BOTH — a seed without an output ceiling, or
    /// vice versa, is an incomplete contract, not a bound) and the
    /// execution-enforced position ceiling.
    func boundedPositionBudget(policyCap: Int?) -> Int? {
        var candidates: [Int] = []
        if let seedCharacters, let maxOutputTokens,
            seedCharacters >= 0, maxOutputTokens > 0
        {
            // chars/4 tokens × 1.5 safety = chars × 3 / 8, rounded up.
            let seedTokens = (seedCharacters * 3 + 7) / 8
            let (requested, overflow) = seedTokens.addingReportingOverflow(maxOutputTokens)
            if !overflow { candidates.append(requested) }
        }
        if let enforcedPositionCeiling, enforcedPositionCeiling > 0 {
            candidates.append(enforcedPositionCeiling)
        }
        guard let tightest = candidates.min() else { return nil }
        // The 4096 floor absorbs the child wrapper/system/template overhead
        // for small requests without inventing a per-request fudge term.
        let floored = max(4096, tightest)
        if let policyCap, policyCap > 0 {
            return min(floored, max(policyCap, 4096))
        }
        return floored
    }
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
    /// Request-bounded per-child active-state price: the same KV/SSM
    /// estimator as `perActiveChildHeadroomBytes` but clamped to what THIS
    /// delegation can actually allocate (seed/input tokens + the child's
    /// configured max output, with margin) instead of the model-wide KV
    /// retention cap. A 2K-output child must not be priced as though it
    /// immediately materializes a 64K-retention cache — on a 16 GB Mac
    /// that difference alone turns an affordable single same-resident-model
    /// child into `ramSlots == 0` (#2221 owns the math; #2498 made the
    /// path common). nil = no request estimate was available; admission
    /// then falls back to the conservative cap-priced value (fail closed,
    /// never cheaper than the physics).
    let requestBoundedChildHeadroomBytes: UInt64?
    let reclaimableBytes: UInt64?
    let releasableParentBytes: UInt64
    let resolvedLoadBudgetBytes: UInt64?
    let osHeadroomBytes: UInt64

    init(
        canonicalModelKey: String,
        targetAlreadyResident: Bool,
        targetLoadFootprintBytes: UInt64?,
        perActiveChildHeadroomBytes: UInt64?,
        requestBoundedChildHeadroomBytes: UInt64? = nil,
        reclaimableBytes: UInt64?,
        releasableParentBytes: UInt64,
        resolvedLoadBudgetBytes: UInt64?,
        osHeadroomBytes: UInt64
    ) {
        self.canonicalModelKey = canonicalModelKey
        self.targetAlreadyResident = targetAlreadyResident
        self.targetLoadFootprintBytes = targetLoadFootprintBytes
        self.perActiveChildHeadroomBytes = perActiveChildHeadroomBytes
        self.requestBoundedChildHeadroomBytes = requestBoundedChildHeadroomBytes
        self.reclaimableBytes = reclaimableBytes
        self.releasableParentBytes = releasableParentBytes
        self.resolvedLoadBudgetBytes = resolvedLoadBudgetBytes
        self.osHeadroomBytes = osHeadroomBytes
    }

    /// The per-child price admission actually uses: the request-bounded
    /// estimate when one exists, never above the conservative cap-priced
    /// estimate (a request estimate can only SHRINK the charge; if a
    /// caller ever supplies a larger one, the conservative value wins so
    /// the estimate cannot inflate past the model-wide envelope).
    var effectiveChildHeadroomBytes: UInt64? {
        switch (requestBoundedChildHeadroomBytes, perActiveChildHeadroomBytes) {
        case (let bounded?, let cap?): return min(bounded, cap)
        case (let bounded?, nil): return bounded
        case (nil, let cap?): return cap
        case (nil, nil): return nil
        }
    }
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
    private static let log = Logger(
        subsystem: "ai.osaurus", category: "SubagentAdmission")

    /// One complete diagnostics line per admission decision. Every term of
    /// the RAM math is named so a 16 GB rejection can be attributed to the
    /// exact term (per-child price vs reclaimable vs OS reserve vs budget)
    /// from the log alone — the precondition for changing the policy.
    private static func logDiagnostics(
        _ input: SubagentBatchAdmissionInput,
        _ plan: SubagentBatchAdmissionPlan
    ) {
        let m = input.memory
        let mb = { (v: UInt64?) -> String in
            v.map { String(format: "%.2fGB", Double($0) / 1_073_741_824) } ?? "nil"
        }
        log.info(
            """
            [admission] model=\(m?.canonicalModelKey ?? "?", privacy: .public) \
            resident=\(m?.targetAlreadyResident ?? false) \
            jobs=\(input.localJobCount)+\(input.remoteJobCount)r \
            limits(agent=\(input.agentParallelLimit) engine=\(input.engineParallelLimit) \
            batching=\(input.continuousBatchingEnabled) ramSafety=\(input.ramSafetyEnabled)) \
            weights=\(mb(m?.targetLoadFootprintBytes), privacy: .public) \
            perChildCap=\(mb(m?.perActiveChildHeadroomBytes), privacy: .public) \
            perChildBounded=\(mb(m?.requestBoundedChildHeadroomBytes), privacy: .public) \
            reclaimable=\(mb(m?.reclaimableBytes), privacy: .public) \
            releasableParent=\(mb(m?.releasableParentBytes), privacy: .public) \
            osReserve=\(mb(m?.osHeadroomBytes), privacy: .public) \
            loadBudget=\(mb(m?.resolvedLoadBudgetBytes), privacy: .public) \
            -> verdict=\(String(describing: plan.verdict), privacy: .public) \
            ramSlots=\(plan.ramSlots.map(String.init) ?? "nil", privacy: .public) \
            localCapacity=\(plan.localCapacity) parallelism=\(plan.localParallelism) \
            limiting=\(plan.limitingFactors.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)
            """)
    }

    static func plan(_ input: SubagentBatchAdmissionInput) -> SubagentBatchAdmissionPlan {
        let plan = planInternal(input)
        logDiagnostics(input, plan)
        return plan
    }

    private static func planInternal(
        _ input: SubagentBatchAdmissionInput
    ) -> SubagentBatchAdmissionPlan {
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

        let perChild = input.memory?.effectiveChildHeadroomBytes
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
            let perChild = positive(facts.effectiveChildHeadroomBytes),
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
