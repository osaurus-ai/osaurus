//
//  ResidencyHandoff.swift
//  OsaurusCore — Subagent framework
//
//  The single optional handoff middleware for model-swapping subagent kinds
//  (spawn, image). When a kind resolves a DIFFERENT local model than the
//  resident orchestrator, the chat model must be unloaded so the subagent
//  model takes the GPU exclusively, then reloaded after the run. Same-model
//  kinds (computer_use) use `PassthroughHandoff` instead.
//
//  Generalized from the residency flow `NativeImageJobCoordinator` and the
//  spawn kind (`TextSubagentKind`) each open-coded. The actual
//  unload/restore/preflight live in
//  `ChatResidencyHandoff`; this wraps them as the host's "around" combinator so
//  restore is guaranteed even when the run throws. The operations are
//  injectable so the control flow (refuse-before-evict → unload → run →
//  restore-always) is unit-testable with no `ModelRuntime`; `.production`
//  wires them to `ChatResidencyHandoff`.
//
//  The KIND owns the per-run `ResidencyPlan` (spawn decides from live GPU
//  residency + its handoff flag; image from its load policy) so this
//  middleware stays generic. Internal to OsaurusCore: kinds construct it in
//  this module and the host drives it via the public `SubagentHandoff`
//  existential.
//

import Foundation

/// What a model-swapping kind decided about residency for one run, resolved at
/// handoff time (right before any eviction) so the decision reflects live GPU
/// state.
struct ResidencyPlan: Sendable {
    /// Free resident chat models for the duration of the run (single
    /// residency). `false` skips unload/restore entirely (e.g. cloud
    /// orchestrator with nothing resident, or a keep-loaded policy).
    var shouldUnload: Bool
    /// On-disk size of the subagent model, for the refuse-before-evict
    /// preflight. `0` skips the size check.
    var requiredBytes: Int64
    /// Whether the RAM-safety preflight is enabled (refuse before evicting if
    /// the subagent model would not fit once the chat model is freed).
    var ramSafetyEnabled: Bool
    /// Idle-wait budget (seconds) before the unload gives up on chat going idle.
    var maxElapsedSeconds: Int
    /// RAM-aware coexistence: a DIFFERENT local model loads alongside the
    /// resident orchestrator (no unload, no restore) because the projection
    /// said both fit under the flexible eviction policy. The handoff still
    /// waits for local chat generation to go idle before the run — the drain
    /// keeps "two resident graphs" from becoming "two GENERATING graphs"
    /// (the BUG G crash class) at run start; process-wide exclusivity for the
    /// run itself comes from the admission class.
    var coexists: Bool

    init(
        shouldUnload: Bool,
        requiredBytes: Int64 = 0,
        ramSafetyEnabled: Bool = false,
        maxElapsedSeconds: Int = 300,
        coexists: Bool = false
    ) {
        self.shouldUnload = shouldUnload
        self.requiredBytes = requiredBytes
        self.ramSafetyEnabled = ramSafetyEnabled
        self.maxElapsedSeconds = maxElapsedSeconds
        self.coexists = coexists
    }

    /// A plan that performs no residency change.
    static let none = ResidencyPlan(shouldUnload: false)
}

/// Residency-backed handoff: refuse-before-evict preflight → unload resident
/// chat models → run → restore (always, even on throw).
struct ResidencyHandoff: SubagentHandoff {
    /// Resolve the per-run plan from the resolved model (kind-specific). Run at
    /// handoff time so `shouldUnload` reflects live residency.
    typealias PlanProvider = @Sendable (ResolvedModel) async -> ResidencyPlan
    /// Refuse-before-evict preflight; throws to abort BEFORE any unload.
    typealias Preflight =
        @Sendable (_ requiredBytes: Int64, _ enabled: Bool, _ onPhase: (String, String) -> Void) async throws -> Void
    /// Unload resident chat models; returns the lease to restore.
    typealias Unload =
        @Sendable (_ maxElapsedSeconds: Int, _ onPhase: (String, String) -> Void) async throws -> ChatResidencyLease
    /// Best-effort restore of an unload lease (logs, never throws).
    typealias Restore = @Sendable (_ lease: ChatResidencyLease, _ onPhase: (String, String) -> Void) async -> [String]

    let plan: PlanProvider
    let preflight: Preflight
    let unload: Unload
    let restore: Restore

    init(
        plan: @escaping PlanProvider,
        preflight: @escaping Preflight,
        unload: @escaping Unload,
        restore: @escaping Restore
    ) {
        self.plan = plan
        self.preflight = preflight
        self.unload = unload
        self.restore = restore
    }

    /// Production wiring: the injectable operations call `ChatResidencyHandoff`.
    static func production(plan: @escaping PlanProvider) -> ResidencyHandoff {
        ResidencyHandoff(
            plan: plan,
            preflight: { requiredBytes, enabled, onPhase in
                try await ChatResidencyHandoff.memoryPreflight(
                    requiredBytes: requiredBytes,
                    enabled: enabled,
                    onPhase: onPhase
                )
            },
            unload: { maxElapsedSeconds, onPhase in
                try await ChatResidencyHandoff.unloadResidentChatModels(
                    maxElapsedSeconds: maxElapsedSeconds,
                    onPhase: onPhase
                )
            },
            restore: { lease, onPhase in
                await ChatResidencyHandoff.restoreBestEffort(lease, onPhase: onPhase)
            }
        )
    }

    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        let plan = await self.plan(resolved)
        let emit: (String, String) -> Void = { phase, detail in
            feed.emitPhase(phase, detail: detail.isEmpty ? nil : detail)
        }

        // Refuse-before-evict: a preflight failure aborts the run BEFORE
        // anything is unloaded, so a too-large job never strands the user with
        // the orchestrator evicted and nothing loaded.
        try await preflight(plan.requiredBytes, plan.ramSafetyEnabled, emit)

        guard plan.shouldUnload else {
            // No residency change (cloud orchestrator / keep-loaded policy).
            return try await body()
        }

        let lease = try await unload(plan.maxElapsedSeconds, emit)
        do {
            let result = try await body()
            _ = await restore(lease, emit)
            return result
        } catch {
            // Restore on the failure path too so the orchestrator is never left
            // unloaded with no diagnostic.
            _ = await restore(lease, emit)
            throw error
        }
    }
}

/// Coexistence handoff: the subagent model loads ALONGSIDE the resident
/// orchestrator (flexible eviction policy + RAM projection passed), so there
/// is nothing to unload or restore. The one residency obligation kept from the
/// single-residency flow is the idle drain: local chat generation must be idle
/// before the run starts, so a second MLX graph never begins producing while
/// another graph is mid-generation (the BUG G crash class). `waitForIdle` is
/// injectable for tests; `.production` wires it to `InferenceLoadCoordinator`.
struct CoexistenceHandoff: SubagentHandoff {
    typealias WaitForIdle = @Sendable (_ timeoutMs: Int) async -> Bool

    let maxElapsedSeconds: Int
    let waitForIdle: WaitForIdle

    static func production(maxElapsedSeconds: Int) -> CoexistenceHandoff {
        CoexistenceHandoff(
            maxElapsedSeconds: maxElapsedSeconds,
            waitForIdle: { timeoutMs in
                await InferenceLoadCoordinator.shared.waitForChatIdle(timeoutMs: timeoutMs)
            }
        )
    }

    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        // Same wait bounds as the unload path (15s floor, 300s ceiling).
        let waitMs = max(15, min(maxElapsedSeconds, 300)) * 1000
        feed.emitPhase(
            "coexisting",
            detail: "keeping the chat model loaded; waiting for local generation to go idle"
        )
        let wentIdle = await waitForIdle(waitMs)
        guard wentIdle else {
            throw SubagentError.unavailable(
                "Local chat generation did not become idle before the coexistence run."
            )
        }
        return try await body()
    }
}
