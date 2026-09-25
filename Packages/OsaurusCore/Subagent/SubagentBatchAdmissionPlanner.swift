//
//  SubagentBatchAdmissionPlanner.swift
//  OsaurusCore — Subagent framework
//
//  Pure capacity policy for one canonical local-model group plus any remote
//  jobs that may overlap it. This is deliberately not a scheduler:
//  the `spawn_agent` wave gate owns fan-out and vMLX `BatchEngine` owns inference.
//

import Darwin
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

/// A failed/unsupported pressure sample is not evidence of normal pressure.
public enum SubagentMemoryPressure: String, Sendable, Codable {
    case normal, warning, critical, unknown

    static func sampled() -> Self {
        var level: Int32 = 0
        var size = MemoryLayout.size(ofValue: level)
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0,
            size == MemoryLayout.size(ofValue: level)
        else { return .unknown }
        return fromKernelLevel(level)
    }

    static func fromKernelLevel(_ level: Int32) -> Self {
        // XNU converts its internal pressure enum to dispatch's public
        // flags for this sysctl (normal=1, warning/urgent=2, critical=4).
        switch UInt32(bitPattern: level) {
        case UInt32(DispatchSource.MemoryPressureEvent.normal.rawValue): return .normal
        case UInt32(DispatchSource.MemoryPressureEvent.warning.rawValue): return .warning
        case UInt32(DispatchSource.MemoryPressureEvent.critical.rawValue): return .critical
        default: return .unknown
        }
    }
}

/// A priced child context contract. Text execution forwards the same position
/// ceiling to the prepared-token boundary, where the complete rendered prompt
/// plus output allowance must fit. Heuristics choose a contract; they do not
/// prove the actual token count.
public struct SubagentChildRequestEstimate: Sendable, Equatable {
    public let seedCharacters: Int?
    public let maxOutputTokens: Int?
    /// Checked by AdmissionPositionLimit after template rendering/tokenization,
    /// including tools, memory and all prior child turns.
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
    func boundedPositionBudget() -> Int? {
        var candidates: [Int] = []
        if let seedCharacters, let maxOutputTokens,
            seedCharacters >= 0, maxOutputTokens > 0
        {
            // chars/4 tokens × 1.5 safety = chars × 3 / 8, rounded up.
            // Every step overflow-checked and failing CLOSED: a value that
            // cannot be represented contributes no candidate, so the fall
            // back is conservative cap pricing, never a wrapped bound.
            let (seedTimes3, mulOverflow) = seedCharacters.multipliedReportingOverflow(by: 3)
            if !mulOverflow {
                let (numerator, addOverflow) = seedTimes3.addingReportingOverflow(7)
                if !addOverflow {
                    let seedTokens = numerator / 8
                    let (requested, sumOverflow) =
                        seedTokens.addingReportingOverflow(maxOutputTokens)
                    if !sumOverflow { candidates.append(requested) }
                }
            }
        }
        // A seed-only estimate carries a minimum composition allowance. It
        // becomes a safety bound only because execution checks it exactly.
        // An explicit delegated contract is already the complete ceiling.
        var floored = candidates.map { max(4096, $0) }
        if let enforcedPositionCeiling, enforcedPositionCeiling > 0 {
            floored.append(enforcedPositionCeiling)
        }
        guard let tightest = floored.min() else { return nil }
        // defaultMaxKVSize is conditional on prompt length in vMLX. It is
        // not a hard retention bound and cannot reduce an admission contract.
        return tightest
    }

    /// Conservative wave envelope for a batch: each job's safe position
    /// budget is resolved independently, and the wave is priced at
    /// the MAXIMUM per-child bound, carried as a pure position ceiling.
    ///
    /// Never combine heterogeneous jobs field-by-field: an estimate built
    /// from "max seed + max output" alongside "max ceiling" would take the
    /// MIN of those two candidate bounds, letting one job's small ceiling
    /// under-price another job's large seed+output request.
    ///
    /// nil (fail closed to cap pricing for the whole canonical-model
    /// group) when the batch is empty or ANY job lacks a valid bound —
    /// a wave must never be under-priced by its cheapest member.
    static func waveEnvelope(
        of estimates: [SubagentChildRequestEstimate?]
    ) -> SubagentChildRequestEstimate? {
        guard !estimates.isEmpty else { return nil }
        var perJobBudgets: [Int] = []
        for estimate in estimates {
            guard let budget = estimate?.boundedPositionBudget() else {
                return nil
            }
            perJobBudgets.append(budget)
        }
        guard let maximum = perJobBudgets.max() else { return nil }
        return SubagentChildRequestEstimate(
            seedCharacters: nil,
            maxOutputTokens: nil,
            enforcedPositionCeiling: maximum
        )
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
    /// Price of the complete enforced child contract. Unknown contracts use
    /// the model context envelope. A soft runtime cache default is not a hard
    /// ceiling and cannot discount either price.
    let requestBoundedChildHeadroomBytes: UInt64?
    let reclaimableBytes: UInt64?
    let releasableParentBytes: UInt64
    let resolvedLoadBudgetBytes: UInt64?
    let osHeadroomBytes: UInt64
    let memoryPressure: SubagentMemoryPressure
    /// Full allocator reuse ceiling for the next generation, including any
    /// MTP/architecture-specific window. Charged once for the shared pool;
    /// do not infer it from the Memory Safety profile's display default.
    let allocatorCacheAllowanceBytes: UInt64?

    init(
        canonicalModelKey: String,
        targetAlreadyResident: Bool,
        targetLoadFootprintBytes: UInt64?,
        perActiveChildHeadroomBytes: UInt64?,
        requestBoundedChildHeadroomBytes: UInt64? = nil,
        reclaimableBytes: UInt64?,
        releasableParentBytes: UInt64,
        resolvedLoadBudgetBytes: UInt64?,
        osHeadroomBytes: UInt64,
        memoryPressure: SubagentMemoryPressure = .unknown,
        allocatorCacheAllowanceBytes: UInt64? = nil
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
        self.memoryPressure = memoryPressure
        self.allocatorCacheAllowanceBytes = allocatorCacheAllowanceBytes
    }

    /// Price the enforced request when known. A soft cache default or a
    /// declared model window must not discount a larger enforced request.
    var effectiveChildHeadroomBytes: UInt64? {
        requestBoundedChildHeadroomBytes ?? perActiveChildHeadroomBytes
    }

    /// A bounded request reusing a resident model allocates child state, not
    /// another OS/app working set. The host sample already excludes resident
    /// anonymous, wired and compressed pages; the child estimate includes KV,
    /// activations and slack, and the model budget remains a second
    /// independent ceiling. Applying the cold-load 3 GiB allowance here made
    /// 512 MiB children fail with more than 2 GiB actually reclaimable.
    ///
    /// Relax only this cold-load allowance, and only with positive evidence:
    /// resident weights, an execution-enforced child bound, a resolved model
    /// budget, a known allocator ceiling and normal kernel pressure. The full
    /// pool ceiling is charged once, conservatively including currently cached
    /// buffers: their physical residency cannot be inferred from MLX bytes.
    /// Unknown/elevated pressure and cold
    /// or unbounded requests retain the existing conservative allowance.
    var usesIncrementalResidentAdmission: Bool {
        targetAlreadyResident && memoryPressure == .normal
            && (requestBoundedChildHeadroomBytes ?? 0) > 0
            && resolvedLoadBudgetBytes != nil
            && allocatorCacheAllowanceBytes != nil
    }

    var effectiveOSHeadroomBytes: UInt64 {
        usesIncrementalResidentAdmission ? 0 : osHeadroomBytes
    }

    var effectiveAllocatorAllowanceBytes: UInt64 {
        usesIncrementalResidentAdmission ? (allocatorCacheAllowanceBytes ?? 0) : 0
    }

}

struct SubagentBatchAdmissionInput: Sendable, Equatable {
    let localJobCount: Int
    let remoteJobCount: Int
    /// Per-agent LOCAL fan-out (`SubagentBudgets.maxParallelSpawns`, mirrored
    /// from Server Concurrent Sessions). Remote jobs never consume it: they
    /// allocate no local model, KV state, or engine slot.
    let agentParallelLimit: Int
    /// Per-agent REMOTE fan-out (`SubagentBudgets.maxRemoteParallelSpawns`).
    /// The tool enforces the exact per-agent value before planning (typed
    /// `invalid_args` the model can correct); the planner re-checks against
    /// whatever the caller passes, defaulting to the schema-wide hard cap.
    var remoteParallelLimit: Int = SubagentBudgets.remoteParallelSpawnBounds.upperBound
    /// vMLX `maxConcurrentSequences`. The planner independently applies the
    /// Continuous Batching toggle so a stale or contradictory caller cannot
    /// accidentally admit concurrent local work while batching is disabled.
    let engineParallelLimit: Int
    /// New submissions allowed by the current engine snapshot, distinct from its total ceiling.
    var engineSubmissionLimit: Int? = nil
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
    /// Preserve the exact sampled inputs with the decision. A later OS sample
    /// must not be presented as the reason for an earlier refusal.
    var memoryFacts: SubagentBatchMemoryFacts? = nil
    /// The policy used for THIS decision, not a later settings snapshot.
    /// With safety off, ramSlots is diagnostic only and cannot veto a child.
    var ramSafetyEnabled = true

    var memoryDiagnostics: [String: Any] {
        var result: [String: Any] = [
            "ram_safety_enabled": ramSafetyEnabled,
            "engine_slots": engineSlots,
            "ram_slots": ramSlots ?? NSNull(),
            "limited_by": limitingFactors.map(\.rawValue).sorted(),
        ]
        guard let m = memoryFacts else { return result }
        result["canonical_model"] = m.canonicalModelKey
        result["target_already_resident"] = m.targetAlreadyResident
        result["target_load_bytes"] = m.targetLoadFootprintBytes ?? NSNull()
        result["per_child_bytes"] = m.effectiveChildHeadroomBytes ?? NSNull()
        result["per_child_cap_bytes"] = m.perActiveChildHeadroomBytes ?? NSNull()
        result["reclaimable_bytes"] = m.reclaimableBytes ?? NSNull()
        result["releasable_parent_bytes"] = m.releasableParentBytes
        result["os_reserve_bytes"] = m.effectiveOSHeadroomBytes
        result["cold_load_reserve_bytes"] = m.osHeadroomBytes
        result["memory_pressure"] = m.memoryPressure.rawValue
        result["resident_incremental"] = m.usesIncrementalResidentAdmission
        result["allocator_allowance_bytes"] = m.effectiveAllocatorAllowanceBytes
        result["load_budget_bytes"] = m.resolvedLoadBudgetBytes ?? NSNull()
        return result
    }
}

enum SubagentBatchAdmissionPlanner {
    /// Resolve live facts at the single-child floor before a caller chooses
    /// its wave width. Both direct spawns and batches use this boundary.
    static func memoryFactsAfterReclaimingIfNeeded(
        isolation: isolated (any Actor)? = #isolation,
        ramSafetyEnabled: Bool,
        sample: () async -> SubagentBatchMemoryFacts?,
        reclaim: () async -> Bool,
        waitForPostReclaimSample: () async throws -> Void = {
            // XNU rate-limits third-party host_statistics64 callers using a
            // shared 1-second cache (osfmk/kern/host.c,
            // rate_limit_host_statistics). A second successful syscall can
            // return the PRE-reclaim counters. Outlive that window before
            // making recovery's final decision; polling it faster cannot
            // force a refresh. The extra 100ms avoids a boundary sample.
            try await Task.sleep(for: .milliseconds(1_100))
        }
    ) async -> SubagentBatchMemoryFacts? {
        let initial = await sample()
        guard ramSafetyEnabled, !Task.isCancelled,
            let facts = initial,
            let footprint = positive(facts.targetLoadFootprintBytes),
            let perChild = positive(facts.effectiveChildHeadroomBytes),
            let capacity = resolveMemoryCapacity(facts), capacity.slots == 0
        else { return initial }
        // Reclamation cannot make a request fit an explicit total budget.
        // Nor do we trim just to widen a batch that can already serialize.
        if let budget = facts.resolvedLoadBudgetBytes,
            saturatingSubtract(budget, saturatingAdd(footprint, facts.effectiveAllocatorAllowanceBytes)) < perChild
        { return initial }
        guard await reclaim(), !Task.isCancelled else { return initial }
        do {
            try await waitForPostReclaimSample()
        } catch {
            return initial
        }
        guard !Task.isCancelled else { return initial }
        let refreshed = await sample()
        log.info(
            "[admission-recovery] model=\(facts.canonicalModelKey, privacy: .public) reclaimable_before=\(facts.reclaimableBytes ?? 0) reclaimable_after=\(refreshed?.reclaimableBytes ?? 0) fresh_estimate_available=\(refreshed != nil)"
        )
        return refreshed
    }

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
            osReserve=\(mb(m?.effectiveOSHeadroomBytes), privacy: .public) \
            pressure=\(m?.memoryPressure.rawValue ?? "unknown", privacy: .public) \
            residentIncremental=\(m?.usesIncrementalResidentAdmission ?? false) \
            allocatorAllowance=\(mb(m?.effectiveAllocatorAllowanceBytes), privacy: .public) \
            loadBudget=\(mb(m?.resolvedLoadBudgetBytes), privacy: .public) \
            -> verdict=\(String(describing: plan.verdict), privacy: .public) \
            ramSlots=\(plan.ramSlots.map(String.init) ?? "nil", privacy: .public) \
            localCapacity=\(plan.localCapacity) parallelism=\(plan.localParallelism) \
            limiting=\(plan.limitingFactors.map(\.rawValue).sorted().joined(separator: ","), privacy: .public)
            """)
    }

    static func plan(_ input: SubagentBatchAdmissionInput) -> SubagentBatchAdmissionPlan {
        var plan = planInternal(input)
        plan.memoryFacts = input.memory
        plan.ramSafetyEnabled = input.ramSafetyEnabled
        logDiagnostics(input, plan)
        return plan
    }

    private static func planInternal(
        _ input: SubagentBatchAdmissionInput
    ) -> SubagentBatchAdmissionPlan {
        let localJobs = max(0, input.localJobCount)
        let remoteJobs = max(0, input.remoteJobCount)
        let engineSlots =
            input.continuousBatchingEnabled
            ? max(1, input.engineParallelLimit)
            : 1

        guard input.agentParallelLimit > 0, input.remoteParallelLimit > 0 else {
            return rejected(
                .invalidParallelLimit,
                engineSlots: engineSlots
            )
        }
        // Local and remote fan-out are independent budgets: a wave of eight
        // cloud workers must not be refused because the local BatchEngine is
        // configured for three concurrent sequences.
        guard localJobs <= input.agentParallelLimit,
            remoteJobs <= input.remoteParallelLimit
        else {
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
        let localSlots = min(localJobs, localCapacity, max(1, input.engineSubmissionLimit ?? engineSlots))

        let perChild = input.memory?.effectiveChildHeadroomBytes
        let incrementalWeight = input.memory.flatMap { facts -> UInt64? in
            facts.targetAlreadyResident ? 0 : facts.targetLoadFootprintBytes
        }
        let activeChildCharge = perChild.map {
            saturatingMultiply($0, UInt64(localSlots))
        }
        let projectedIncrementalPeak =
            zipOptionals(incrementalWeight, activeChildCharge).map {
                saturatingAdd(saturatingAdd($0.0, $0.1), input.memory?.effectiveAllocatorAllowanceBytes ?? 0)
            }
        let projectedModelWorkingSet =
            zipOptionals(input.memory?.targetLoadFootprintBytes, activeChildCharge)
            .map { saturatingAdd(saturatingAdd($0.0, $0.1), input.memory?.effectiveAllocatorAllowanceBytes ?? 0) }

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

        guard facts.memoryPressure != .critical else { return MemoryCapacity(slots: 0) }
        let incrementalWeight = facts.targetAlreadyResident ? 0 : footprint
        let availableBeforeReserve = saturatingAdd(
            reclaimable,
            facts.releasableParentBytes
        )
        let availableFixedCharge = saturatingAdd(
            incrementalWeight,
            saturatingAdd(facts.effectiveOSHeadroomBytes, facts.effectiveAllocatorAllowanceBytes)
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
            let budgetResidual = saturatingSubtract(
                budget, saturatingAdd(footprint, facts.effectiveAllocatorAllowanceBytes)
            )
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
            perActiveChildHeadroomBytes: memory?.effectiveChildHeadroomBytes,
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

    private static func clampedSlotCount(_ value: UInt64) -> Int {
        value > UInt64(Int.max) ? Int.max : Int(value)
    }

    private static func zipOptionals<T, U>(_ lhs: T?, _ rhs: U?) -> (T, U)? {
        guard let lhs, let rhs else { return nil }
        return (lhs, rhs)
    }
}
