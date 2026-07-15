//
//  AppleScriptWarmResidency.swift
//  OsaurusCore — Subagent framework
//
//  Keep-warm residency for the AppleScript subagent. The AppleScript bundle is
//  ALWAYS a different model than the resident chat model, so a run must unload
//  chat → load AppleScript → run → reload chat (single-GPU residency, via
//  `ResidencyHandoff`). Back-to-back `applescript` / `mac_query` calls pay that
//  whole round-trip each time.
//
//  Under `AppleScriptLoadPolicy.keepWarmAfterJob`, this middleware instead keeps
//  the AppleScript model resident for a short window after a run and DEFERS the
//  chat reload. A follow-up AppleScript call within the window adopts the still-
//  unloaded lease (the chat models the previous run freed) and reuses the
//  resident AppleScript model — skipping the unload/reload entirely. When the
//  window elapses with no follow-up, the deferred restore reloads the chat
//  model.
//
//  Single-residency envelope preserved: during the warm window exactly ONE
//  model (the AppleScript bundle) is resident and NOTHING is generating, so it
//  stays inside the one-resident-model invariant. If a chat turn starts during
//  the window it reloads the chat model through the normal on-demand path
//  (evicting the AppleScript model under strict eviction, or coexisting under
//  the flexible policy the coexistence gate already governs); the deferred
//  restore is idempotent (`restoreBestEffort` verifies residency) so it never
//  double-loads. The run itself still holds the GPU exclusively via the kind's
//  admission class.
//

import Foundation

/// Process-wide owner of the deferred chat-model restore for the AppleScript
/// keep-warm window. Holds at most one warm lease (the chat models a prior run
/// unloaded) plus the AppleScript model kept resident for it, and a single
/// scheduled restore task guarded by a monotonic token so a stale timer can
/// never restore after a newer run took over.
actor AppleScriptWarmResidencyCoordinator {
    static let shared = AppleScriptWarmResidencyCoordinator()

    /// Chat models unloaded for the currently-warm AppleScript model, pending a
    /// deferred restore. `nil` when nothing is held warm.
    private var heldLease: ChatResidencyLease?
    /// The AppleScript model currently held resident (so a run for a DIFFERENT
    /// model releases the hold instead of adopting it). Compared case-insensitively.
    private var heldModel: String?
    /// The scheduled deferred restore; cancelled when a run adopts the hold or a
    /// newer hold replaces it.
    private var restoreTask: Task<Void, Never>?
    /// Monotonic guard: a deferred restore only fires when its captured token
    /// still matches, so a cancelled/replaced timer is a no-op even if it wakes.
    private var token = 0

    /// Restore seam (injectable for tests). Production reloads the chat models
    /// via `ChatResidencyHandoff` best-effort (logs, never throws).
    private let restore: @Sendable (ChatResidencyLease) async -> Void
    /// Sleep seam (injectable for tests) so the deferred-restore delay is
    /// deterministic under test.
    private let sleep: @Sendable (_ seconds: Int) async -> Void

    init(
        restore: @escaping @Sendable (ChatResidencyLease) async -> Void = {
            await ChatResidencyHandoff.restoreBestEffort($0)
        },
        sleep: @escaping @Sendable (_ seconds: Int) async -> Void = { seconds in
            try? await Task.sleep(nanoseconds: UInt64(max(0, seconds)) * 1_000_000_000)
        }
    ) {
        self.restore = restore
        self.sleep = sleep
    }

    /// Begin an AppleScript run for `model`. If a warm hold exists for the SAME
    /// model, adopt it: cancel the pending restore and return its lease so the
    /// caller reuses the already-unloaded chat models (no unload). If a hold
    /// exists for a DIFFERENT model, restore it now (that model is being
    /// replaced) and return `nil`. `nil` means "no warm hold — unload normally".
    func beginRun(model: String) async -> ChatResidencyLease? {
        token += 1
        restoreTask?.cancel()
        restoreTask = nil
        let previousLease = heldLease
        let previousModel = heldModel
        heldLease = nil
        heldModel = nil

        if let previousModel, previousModel.caseInsensitiveCompare(model) == .orderedSame,
            let previousLease
        {
            return previousLease
        }
        // A hold for a different model is being replaced by this run — restore
        // it before the run unloads for its own model.
        if let previousLease, !previousLease.isEmpty {
            await restore(previousLease)
        }
        return nil
    }

    /// End an AppleScript run. Under keep-warm (`keepWarmSeconds > 0`) with a
    /// non-empty lease, hold `model` resident and schedule the chat restore for
    /// `keepWarmSeconds` from now. Otherwise restore immediately.
    func endRun(lease: ChatResidencyLease, model: String, keepWarmSeconds: Int) async {
        guard keepWarmSeconds > 0, !lease.isEmpty else {
            if !lease.isEmpty { await restore(lease) }
            return
        }
        token += 1
        let myToken = token
        heldLease = lease
        heldModel = model
        restoreTask = Task { [weak self, sleep] in
            await sleep(keepWarmSeconds)
            await self?.fireDeferredRestore(myToken)
        }
    }

    /// Fire the deferred restore iff it's still the current hold (`myToken`
    /// unchanged). A superseded timer is a no-op.
    private func fireDeferredRestore(_ myToken: Int) async {
        guard myToken == token, let lease = heldLease else { return }
        heldLease = nil
        heldModel = nil
        restoreTask = nil
        await restore(lease)
    }

    /// Flush any warm hold NOW (restore the chat model immediately). Used before
    /// a different local model must load, or to reclaim the hold on teardown.
    func flush() async {
        token += 1
        restoreTask?.cancel()
        restoreTask = nil
        guard let lease = heldLease else { return }
        heldLease = nil
        heldModel = nil
        if !lease.isEmpty { await restore(lease) }
    }

    /// Test-only view of the current hold (model name, or nil when none).
    func heldModelForTesting() -> String? { heldModel }
}

/// Keep-warm residency middleware for the AppleScript kind. Wraps the standard
/// unload→run→reload flow (`ResidencyHandoff`) but routes the chat restore
/// through `AppleScriptWarmResidencyCoordinator` so it can be deferred and a
/// follow-up run can adopt it. Falls back to an immediate restore on the
/// failure path (a failed run should not strand chat unloaded on a warm timer).
struct AppleScriptWarmResidencyHandoff: SubagentHandoff {
    let plan: ResidencyPlan
    let model: String
    let keepWarmSeconds: Int
    let coordinator: AppleScriptWarmResidencyCoordinator

    /// Refuse-before-evict preflight (injectable; production → `ChatResidencyHandoff`).
    let preflight:
        @Sendable (_ requiredBytes: Int64, _ enabled: Bool, _ onPhase: (String, String) -> Void)
            async throws -> Void
    /// Unload resident chat models, returning the lease (injectable).
    let unload:
        @Sendable (_ maxElapsedSeconds: Int, _ onPhase: (String, String) -> Void) async throws ->
            ChatResidencyLease
    /// Immediate restore for the failure path (injectable).
    let restoreNow: @Sendable (_ lease: ChatResidencyLease, _ onPhase: (String, String) -> Void) async -> Void

    /// Production wiring against `ChatResidencyHandoff`.
    static func production(
        plan: ResidencyPlan,
        model: String,
        keepWarmSeconds: Int,
        coordinator: AppleScriptWarmResidencyCoordinator = .shared
    ) -> AppleScriptWarmResidencyHandoff {
        AppleScriptWarmResidencyHandoff(
            plan: plan,
            model: model,
            keepWarmSeconds: keepWarmSeconds,
            coordinator: coordinator,
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
            restoreNow: { lease, onPhase in
                _ = await ChatResidencyHandoff.restoreBestEffort(lease, onPhase: onPhase)
            }
        )
    }

    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        let emit: (String, String) -> Void = { phase, detail in
            feed.emitPhase(phase, detail: detail.isEmpty ? nil : detail)
        }

        // A warm hold for THIS model means chat is already unloaded and the
        // AppleScript model resident — adopt the lease and skip the swap.
        if let adopted = await coordinator.beginRun(model: model) {
            emit("reusing_applescript_model", model)
            do {
                let result = try await body()
                await coordinator.endRun(
                    lease: adopted,
                    model: model,
                    keepWarmSeconds: keepWarmSeconds
                )
                return result
            } catch {
                await restoreNow(adopted, emit)
                throw error
            }
        }

        // Cold path: refuse-before-evict, then unload chat for this run.
        try await preflight(plan.requiredBytes, plan.ramSafetyEnabled, emit)
        guard plan.shouldUnload else {
            // Nothing resident to unload (cloud orchestrator / already ours), so
            // there's nothing to keep warm either.
            return try await body()
        }
        let lease = try await unload(plan.maxElapsedSeconds, emit)
        do {
            let result = try await body()
            // Keep the AppleScript model warm: defer the chat restore.
            await coordinator.endRun(lease: lease, model: model, keepWarmSeconds: keepWarmSeconds)
            return result
        } catch {
            await restoreNow(lease, emit)
            throw error
        }
    }
}
