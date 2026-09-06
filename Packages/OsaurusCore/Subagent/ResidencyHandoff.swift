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
    /// The user turned the "Local Orchestrator Handoff" toggle OFF and the
    /// delegate is a DIFFERENT local model: the run proceeds with NO
    /// unload/reload sequencing (the runtime's own eviction policy decides
    /// what happens to the chat model). Never a refusal — this flag exists
    /// so the tool result and activity readout can say so.
    var sequencingDisabled: Bool

    init(
        shouldUnload: Bool,
        requiredBytes: Int64 = 0,
        ramSafetyEnabled: Bool = false,
        maxElapsedSeconds: Int = 300,
        coexists: Bool = false,
        sequencingDisabled: Bool = false
    ) {
        self.shouldUnload = shouldUnload
        self.requiredBytes = requiredBytes
        self.ramSafetyEnabled = ramSafetyEnabled
        self.maxElapsedSeconds = maxElapsedSeconds
        self.coexists = coexists
        self.sequencingDisabled = sequencingDisabled
    }

    /// A plan that performs no residency change.
    static let none = ResidencyPlan(shouldUnload: false)

    /// Stable readout token for the tool result / diagnostics.
    var mode: String {
        if shouldUnload { return "swap_unload_reload" }
        if coexists { return "coexist" }
        if sequencingDisabled { return "sequencing_off" }
        return "in_place"
    }
}

/// The delegation RAM-safety sequence as DATA, so the order is one testable
/// value instead of an emergent property of three collaborating types:
///
///   unload main → (hand off) load delegate → run → unload delegate → reload main
///
/// Derived from a resolved `ResidencyPlan` plus what the unload leg actually
/// found. Same-model, cloud, coexistence and toggle-off runs collapse to
/// `[.run]` (no churn). The middleware emits the realized steps into the
/// subagent feed and the tool payload (`handoff_sequence` / `handoff_summary`)
/// so the user can see the swap happen and be undone.
enum DelegationResidencySequence {
    enum Step: Equatable, Sendable, CustomStringConvertible {
        case unloadMain(String)
        case loadDelegate(String)
        case run
        case unloadDelegate(String)
        case reloadMain(String)

        var description: String {
            switch self {
            case .unloadMain(let name): return "unload_main:\(name)"
            case .loadDelegate(let name): return "load_delegate:\(name)"
            case .run: return "run"
            case .unloadDelegate(let name): return "unload_delegate:\(name)"
            case .reloadMain(let name): return "reload_main:\(name)"
            }
        }
    }

    /// The ordered steps for one delegation. `mainResident` is whether the
    /// chat model was loaded when the sequence began (false ⇒ the unload leg
    /// is skipped but the reload leg still runs — parity across both states).
    /// `mainModelName` nil (cloud / unknown parent) with a swap plan degrades
    /// to a delegate-only load/unload, which the readout labels honestly.
    static func steps(
        plan: ResidencyPlan,
        mainModelName: String?,
        mainResident: Bool,
        delegateModelName: String
    ) -> [Step] {
        guard plan.shouldUnload else { return [.run] }
        var steps: [Step] = []
        if mainResident, let mainModelName {
            steps.append(.unloadMain(mainModelName))
        }
        steps.append(.loadDelegate(delegateModelName))
        steps.append(.run)
        steps.append(.unloadDelegate(delegateModelName))
        if let mainModelName {
            steps.append(.reloadMain(mainModelName))
        }
        return steps
    }

    /// One human sentence for the tool result / activity feed.
    static func summary(
        plan: ResidencyPlan,
        mainModelName: String?,
        mainResident: Bool,
        delegateModelName: String
    ) -> String {
        let main = mainModelName ?? "the chat model"
        if plan.shouldUnload {
            if mainResident {
                return
                    "swapped chat model '\(main)' out for delegate '\(delegateModelName)'; "
                    + "unloaded the delegate and loaded '\(main)' back after the run"
            }
            return
                "chat model '\(main)' was not loaded; ran delegate '\(delegateModelName)', "
                + "unloaded it, then loaded '\(main)' for the chat turn"
        }
        if plan.coexists {
            return
                "kept chat model '\(main)' loaded and ran delegate '\(delegateModelName)' "
                + "alongside it (coexistence)"
        }
        if plan.sequencingDisabled {
            return
                "Local Orchestrator Handoff is off: ran delegate '\(delegateModelName)' "
                + "without the unload/reload sequence; the runtime's eviction policy "
                + "decides whether '\(main)' stays loaded"
        }
        return "delegate '\(delegateModelName)' ran in place; no model swap was needed"
    }
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
        @Sendable (
            _ parentModelName: String?,
            _ maxElapsedSeconds: Int,
            _ onPhase: (String, String) -> Void
        ) async throws -> ChatResidencyLease
    /// Restore an unload lease. Unlike image-result preservation, text
    /// delegation cannot report success while its orchestrator remains
    /// unloaded, so restore failure is part of this handoff's outcome.
    typealias Restore =
        @Sendable (_ lease: ChatResidencyLease, _ onPhase: (String, String) -> Void) async throws
            -> [String]
    /// Sequence leg "unload the delegate model" — release the child model(s)
    /// this handoff cold-loaded, BEFORE the main model is reloaded. Optional
    /// so single-step fixtures keep compiling; production wires it to
    /// `ChatResidencyHandoff.releaseOwnedChildModels` and `restore` to the
    /// reload-only leg, which makes the two legs individually observable.
    typealias ReleaseDelegate =
        @Sendable (_ lease: ChatResidencyLease, _ onPhase: (String, String) -> Void) async throws
            -> [String]

    let plan: PlanProvider
    let preflight: Preflight
    let unload: Unload
    let restore: Restore
    let releaseDelegate: ReleaseDelegate?

    init(
        plan: @escaping PlanProvider,
        preflight: @escaping Preflight,
        unload: @escaping Unload,
        restore: @escaping Restore,
        releaseDelegate: ReleaseDelegate? = nil
    ) {
        self.plan = plan
        self.preflight = preflight
        self.unload = unload
        self.restore = restore
        self.releaseDelegate = releaseDelegate
    }

    /// Production wiring: the injectable operations call `ChatResidencyHandoff`.
    ///
    /// The unload leg passes `restoreParentWhenNotResident: true`: a swap plan
    /// only exists when the user's handoff toggle is ON and the delegate is a
    /// different local model, and the product rule is that the sequence ends
    /// with the chat model loaded back whether or not it was loaded at the
    /// start.
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
            unload: { parentModelName, maxElapsedSeconds, onPhase in
                try await ChatResidencyHandoff.unloadResidentChatModels(
                    parentModelName: parentModelName,
                    maxElapsedSeconds: maxElapsedSeconds,
                    restoreParentWhenNotResident: true,
                    onPhase: onPhase
                )
            },
            restore: { lease, onPhase in
                try await ChatResidencyHandoff.reloadParent(lease, onPhase: onPhase)
            },
            releaseDelegate: { lease, onPhase in
                try await ChatResidencyHandoff.releaseOwnedChildModels(lease, onPhase: onPhase)
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

        // Step 1 — unload the main chat model (or, when it is not loaded,
        // record the restore-only lease so step 6 still runs).
        let lease = try await unload(
            scope.parentModelName,
            plan.maxElapsedSeconds,
            emit
        )
        let mainModelName =
            lease.restoreModelNames.first ?? scope.parentModelName
        let mainWasResident = !lease.unloadedModelNames.isEmpty
        // Steps 2–4 — hand the task to the delegate; its model cold-loads
        // under this lease's ownership token so step 5 can release exactly it.
        feed.emitPhase(
            "handing_off_to_delegate",
            detail: mainWasResident
                ? "chat model unloaded; loading delegate \(resolved.name)"
                : "chat model was not loaded; loading delegate \(resolved.name)"
        )
        var result: SubagentResult
        do {
            result = try await ModelResidencyOwnershipContext.$childOwnershipToken.withValue(
                lease.childOwnershipToken
            ) {
                try await body()
            }
        } catch let bodyError {
            // Steps 5–6 on the failure path too so the orchestrator is never
            // left unloaded with no diagnostic. This cleanup must not inherit
            // the cancelled child task: model preload checks cancellation, so
            // running restore inline after Stop can otherwise fail before the
            // different-local orchestrator is resident again.
            do {
                _ = try await restoreOutsideCancelledRun(lease, feed: feed)
            } catch let restoreError {
                throw ResidencyHandoffFailure.bodyAndRestoreFailed(
                    body: Self.errorContext(bodyError),
                    restore: Self.errorContext(restoreError)
                )
            }
            throw bodyError
        }
        // Steps 5–6 — unload the delegate, load the main chat model back.
        _ = try await restoreOutsideCancelledRun(lease, feed: feed)

        // Step 7 belongs to the caller (the chat turn continues). Surface what
        // happened so the user can see the swap in the tool result + feed.
        let steps = DelegationResidencySequence.steps(
            plan: plan,
            mainModelName: mainModelName,
            mainResident: mainWasResident,
            delegateModelName: resolved.name
        )
        let summary = DelegationResidencySequence.summary(
            plan: plan,
            mainModelName: mainModelName,
            mainResident: mainWasResident,
            delegateModelName: resolved.name
        )
        feed.emit(
            SubagentActivityEvent(kind: .narrate, title: "model swap", detail: summary)
        )
        result.payload["handoff_sequence"] = steps.map(\.description)
        result.payload["handoff_summary"] = summary
        return result
    }

    /// Restore is owned cleanup, not child work. Run it in a fresh detached
    /// task (no inherited cancellation) and await that task to completion
    /// before the handoff returns. This is deliberately not fire-and-forget:
    /// the caller cannot release admission or finish the tool card while the
    /// original chat model is still absent.
    ///
    /// Order inside the task is fixed: release the delegate model FIRST
    /// (when the handoff owns one), THEN reload the main chat model — the
    /// two are never resident together on the way back either.
    private func restoreOutsideCancelledRun(
        _ lease: ChatResidencyLease,
        feed: SubagentFeed
    ) async throws -> [String] {
        let restore = self.restore
        let releaseDelegate = self.releaseDelegate
        let operation = Task.detached(priority: .userInitiated) {
            let onPhase: (String, String) -> Void = { phase, detail in
                feed.emitPhase(phase, detail: detail.isEmpty ? nil : detail)
            }
            if let releaseDelegate {
                _ = try await releaseDelegate(lease, onPhase)
            }
            return try await restore(lease, onPhase)
        }
        return try await operation.value
    }

    private static func errorContext(_ error: Error) -> String {
        "\(String(reflecting: type(of: error))): \(error.localizedDescription)"
    }
}

/// A child failure and a restore failure are both material. Swift can throw
/// only one value, so preserve both typed contexts in one actionable error
/// rather than replacing the child error with the cleanup error or silently
/// returning the child result.
enum ResidencyHandoffFailure: Error, LocalizedError, Sendable, Equatable {
    case bodyAndRestoreFailed(body: String, restore: String)

    var errorDescription: String? {
        switch self {
        case .bodyAndRestoreFailed(let body, let restore):
            return
                "The subagent failed and its orchestrator could not be restored. "
                + "Subagent failure: \(body). Restore failure: \(restore)."
        }
    }
}

/// Attach one exact ownership token to cold model loads performed by an
/// otherwise non-evicting handoff. Batch sequences use this wrapper when there
/// is no parent model to unload, or when children may coexist with the parent.
///
/// The runtime records the token only on a cold-published residency. Reusing a
/// pre-existing local/API/plugin resident does not acquire ownership, so later
/// transitions and final cleanup remain fail-closed for unrelated models.
struct ResidencyOwnershipHandoff: SubagentHandoff {
    let wrapped: any SubagentHandoff
    let ownershipToken: ModelResidencyOwnershipToken

    init(
        wrapping wrapped: any SubagentHandoff,
        ownershipToken: ModelResidencyOwnershipToken = ModelResidencyOwnershipToken()
    ) {
        self.wrapped = wrapped
        self.ownershipToken = ownershipToken
    }

    func around(
        scope: SubagentScope,
        resolved: ResolvedModel,
        feed: SubagentFeed,
        run body: () async throws -> SubagentResult
    ) async throws -> SubagentResult {
        // A future nested fan-out must remain in the outer handoff's exact
        // ownership domain. Replacing an inherited token would let the inner
        // scope clear the outer owner's cleanup claim.
        let scopedToken =
            ModelResidencyOwnershipContext.childOwnershipToken ?? ownershipToken
        return try await ModelResidencyOwnershipContext.$childOwnershipToken.withValue(
            scopedToken
        ) {
            try await wrapped.around(
                scope: scope,
                resolved: resolved,
                feed: feed,
                run: body
            )
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
