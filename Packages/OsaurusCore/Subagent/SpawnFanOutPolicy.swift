//
//  SpawnFanOutPolicy.swift
//  OsaurusCore — Subagent framework
//
//  Shared fan-out policy for delegation. Several `spawn_agent` calls in one
//  model message form one wave (`SpawnWaveGate`); this type owns the limits
//  that wave is checked against and the local-admission bridge that decides
//  how many same-model children may run at once.
//

import Foundation

enum SpawnFanOutPolicy {
    /// Typed, retryable message for a wave that asks for more workers than
    /// the launcher allows.
    static func fanOutLimitMessage(requested: Int, limit: Int, kind: String) -> String {
        "This wave asks for \(requested) \(kind) subagents, but this agent allows at most "
            + "\(limit) \(kind) subagents at once. Run the extra work after these finish, "
            + "or ask the user to raise the limit in the Subagents settings."
    }

    /// Per-launcher fan-out limits: `local` mirrors the Server Concurrent
    /// Sessions ceiling; `remote` is independent (cloud / workspace workers
    /// consume no local GPU or RAM).
    /// Deterministic eval seam. Production never binds this value; scripted
    /// wave evaluations pin the fan-out ceiling so a developer machine's
    /// persisted limits cannot change the contract under test.
    @TaskLocal
    static var limitsOverrideForTests: SpawnFanOutLimits?

    @MainActor
    static func effectiveFanOutLimits(scope: SubagentScope) -> SpawnFanOutLimits {
        if let limitsOverrideForTests { return limitsOverrideForTests }
        let budgets = effectiveBudgets(scope: scope)
        return SpawnFanOutLimits(
            local: budgets.maxParallelSpawns,
            remote: budgets.maxRemoteParallelSpawns
        )
    }

    @MainActor
    static func effectiveMaxParallel(scope: SubagentScope) -> Int {
        effectiveBudgets(scope: scope).maxParallelSpawns
    }

    @MainActor
    static func effectiveBudgets(scope: SubagentScope) -> SubagentBudgets {
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let settings = AgentManager.shared.agent(for: scope.agentId)?.settings
        return SubagentToolVisibility.effectiveBudgets(
            isDefault: isDefault,
            config: config,
            settings: settings,
            sharedParallelLimit: SpawnBatchConcurrencyContract.configuredLimit(
                for: ServerRuntimeSettingsStore.snapshot()
            )
        ).normalized
    }

    /// This caller's bound on NEW submissions to the vMLX batch engine,
    /// derived from an actor-consistent capacity snapshot.
    struct EngineAdmissionWindow: Sendable, Equatable {
        let parallelLimit: Int
        let queued: Bool
    }

    /// Bound only this caller's new submissions from an actor-consistent vMLX
    /// snapshot. Deliberately not a reservation: BatchEngine remains the
    /// final admission authority if another chat/API/tool request races
    /// after the observation. A free engine slot is never subtracted again
    /// by sibling reservations (see `RAMAdmissionAuditProbes`).
    static func engineAdmissionWindow(
        configuredMaximum: Int,
        snapshot: ModelBatchCapacitySnapshot?
    ) -> EngineAdmissionWindow {
        let configured = max(1, configuredMaximum)
        guard let snapshot else {
            return EngineAdmissionWindow(parallelLimit: configured, queued: false)
        }
        let queued =
            !snapshot.isAcceptingRequests
            || snapshot.pendingCount > 0
            || snapshot.nominalAvailableCount == 0
        guard !queued else {
            // Keep one explicit queued child rather than enqueueing the whole
            // wave behind unrelated chat/API/tool work.
            return EngineAdmissionWindow(parallelLimit: 1, queued: true)
        }
        return EngineAdmissionWindow(
            parallelLimit: max(1, min(configured, snapshot.nominalAvailableCount)),
            queued: false
        )
    }

    /// Pure residency-to-capacity bridge used by production after resolving
    /// live runtime facts and by model-free tests. Keeping this mapping in one
    /// place prevents a same-resident `.none` shortcut from silently disabling
    /// the global RAM-safety policy before the admission planner sees it.
    static func makeLocalAdmissionPlan(
        localJobCount: Int,
        remoteJobCount: Int,
        maxParallel: Int,
        engineParallelLimit: Int,
        engineSubmissionLimit: Int? = nil,
        continuousBatchingEnabled: Bool,
        residencyPlan: ResidencyPlan?,
        memoryFacts: SubagentBatchMemoryFacts?,
        failClosedWhenEstimateUnknown: Bool
    ) -> SubagentBatchAdmissionPlan {
        SubagentBatchAdmissionPlanner.plan(
            SubagentBatchAdmissionInput(
                localJobCount: localJobCount,
                remoteJobCount: remoteJobCount,
                agentParallelLimit: maxParallel,
                engineParallelLimit: engineParallelLimit,
                engineSubmissionLimit: engineSubmissionLimit,
                continuousBatchingEnabled: continuousBatchingEnabled,
                ramSafetyEnabled: residencyPlan?.ramSafetyEnabled ?? false,
                failClosedWhenEstimateUnknown: failClosedWhenEstimateUnknown,
                memory: memoryFacts
            )
        )
    }
}
