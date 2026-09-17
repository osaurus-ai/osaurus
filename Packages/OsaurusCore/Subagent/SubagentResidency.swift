//
//  SubagentResidency.swift
//  OsaurusCore — Subagent framework
//
//  The shared model-residency layer for the chat-driven subagent kinds
//  (spawn, computer_use). When a kind resolves a model that is
//  a DIFFERENT local bundle than the resident orchestrator, single-GPU
//  residency requires unloading the chat model for the run and reloading it
//  after — exactly the flow `spawn` (`TextSubagentKind`) pioneered. This
//  generalizes that decision so every kind reads it once instead of
//  re-deriving the live-residency check + reject-before-evict gate inline.
//
//  The decision is split into a pure `decidePlan` (no `ModelRuntime` /
//  `ModelManager`, so it unit-tests with no GPU) and a live `resolve` wrapper
//  the kinds call. `handoff(for:)` maps a resolved plan onto the host's
//  `SubagentHandoff` middleware (a real `ResidencyHandoff` when it unloads,
//  otherwise the passthrough default).
//

import Foundation

/// The residency outcome a kind resolves up front (reject-before-evict): the
/// `isLocal` flag for its `ResolvedModel` plus the `ResidencyPlan` the
/// `makeHandoff()` middleware runs (or `.none` for no swap).
struct SubagentResidencyDecision: Sendable {
    /// True when the resolved model is an installed local bundle (so the host's
    /// handoff middleware may need single-GPU-residency eviction).
    let isLocal: Bool
    /// The per-run residency plan. `.none` means run in place (remote model,
    /// same as the resident orchestrator, or nothing else resident).
    let plan: ResidencyPlan
}

enum SubagentResidency {
    /// Pure residency decision — the delegation RAM-safety decision table, no
    /// `ModelRuntime` / `ModelManager`, so it unit-tests with no GPU:
    ///
    ///   remote delegate                          ⇒ run in place (no swap)
    ///   same model as the invoking parent        ⇒ run in place (no churn)
    ///   different local + handoff toggle ON      ⇒ unload main → load delegate
    ///                                              → run → unload delegate →
    ///                                              reload main (also when the
    ///                                              main model is NOT loaded:
    ///                                              the reload leg still runs)
    ///   different local + handoff toggle OFF     ⇒ retain the invoking parent
    ///                                              for the job, load the child
    ///                                              alongside it, clean up only
    ///                                              the job's owned child.
    /// Memory admission is separate: refusal must never fall back to eviction.
    ///
    /// `residentChatModels` is the live set of resident chat-model names that
    /// belong to the invoking parent (empty when the model isn't local or the
    /// parent is not loaded). `invokingParentModelName` is the parent's
    /// canonical INSTALLED local name (nil for a cloud/unknown parent) so the
    /// not-loaded state can still schedule the reload leg. `deniedMessage` is
    /// retained for call-site compatibility; the toggle no longer refuses.
    static func decidePlan(
        isLocal: Bool,
        modelName: String,
        residentChatModels: [String],
        protectedResidentModels: [String] = [],
        handoffEnabled: Bool,
        ramSafetyEnabled: Bool,
        requiredBytes: Int64,
        idleWaitSeconds: Int,
        deniedMessage: String,
        invokingParentModelName: String? = nil
    ) throws -> ResidencyPlan {
        // A remote/router model never touches local GPU residency.
        guard isLocal else { return .none }
        // Only a DIFFERENT resident chat model forces a swap; the same model
        // already resident is reused in place. Preserve the owning RAM-safety
        // policy and target footprint even though no handoff is required:
        // same-model batched children still allocate independent KV/SSM and
        // activation state, so returning the hard-coded `.none` plan here
        // would silently disable the batch admission memory clamp.
        let targetIsInvokingParentResident = residentChatModels.contains {
            $0.caseInsensitiveCompare(modelName) == .orderedSame
        }
        if targetIsInvokingParentResident {
            // The invoking parent already owns the exact target model. This
            // spawn neither loads a model nor unloads/restores residency, so an
            // unrelated protected API/plugin model is not in its ownership
            // path and must not cause a false refusal.
            return ResidencyPlan(
                shouldUnload: false,
                requiredBytes: requiredBytes,
                ramSafetyEnabled: ramSafetyEnabled,
                maxElapsedSeconds: idleWaitSeconds
            )
        }

        let otherResidentModels = residentChatModels.filter {
            $0.caseInsensitiveCompare(modelName) != .orderedSame
        }
        if !handoffEnabled,
            !otherResidentModels.isEmpty
                || invokingParentModelName.map({ $0.caseInsensitiveCompare(modelName) != .orderedSame }) == true
        {
            return ResidencyPlan(
                shouldUnload: false,
                requiredBytes: requiredBytes,
                ramSafetyEnabled: ramSafetyEnabled,
                maxElapsedSeconds: idleWaitSeconds,
                coexists: true
            )
        }
        guard !otherResidentModels.isEmpty else {
            let unrelatedProtectedModels = protectedResidentModels.filter {
                $0.caseInsensitiveCompare(modelName) != .orderedSame
            }
            guard unrelatedProtectedModels.isEmpty else {
                throw SubagentError.unavailable(
                    "Cannot load local subagent model '\(modelName)' because no exact invoking "
                        + "parent is reclaimable and unrelated resident model(s) are protected: "
                        + unrelatedProtectedModels.sorted().joined(separator: ", ")
                        + ". Finish the other local work or select the same resident model."
                )
            }
            // Parity leg: the invoking parent is a known local model that is
            // NOT loaded right now (evicted, or never warmed). With the
            // handoff toggle ON the sequence still ends with the chat model
            // loaded back, so schedule the swap plan — its unload leg finds
            // nothing to unload and returns a restore-only lease.
            if handoffEnabled,
                let invokingParentModelName,
                invokingParentModelName.caseInsensitiveCompare(modelName) != .orderedSame
            {
                return ResidencyPlan(
                    shouldUnload: true,
                    requiredBytes: requiredBytes,
                    ramSafetyEnabled: ramSafetyEnabled,
                    maxElapsedSeconds: idleWaitSeconds
                )
            }
            return ResidencyPlan(
                shouldUnload: false,
                requiredBytes: requiredBytes,
                ramSafetyEnabled: ramSafetyEnabled,
                maxElapsedSeconds: idleWaitSeconds
            )
        }
        // Reusing a protected target is safe only in keep-parent mode. Unloading the
        // parent and running on an API/plugin/scheduled-owned target would
        // strand the parent: restore correctly refuses to evict a resident the
        // handoff does not own. Refuse before touching the parent.
        let protectedTargetIsResident = protectedResidentModels.contains {
            $0.caseInsensitiveCompare(modelName) == .orderedSame
        }
        guard !protectedTargetIsResident else {
            throw SubagentError.unavailable(
                "Cannot hand off from the invoking local model to protected resident "
                    + "'\(modelName)' because the parent cannot be restored without "
                    + "evicting unrelated API/plugin/scheduled work. Enable a RAM-safe "
                    + "coexistence configuration or finish the protected work first."
            )
        }

        // A single-residency handoff may reclaim only chat-owned models. If an
        // unrelated API/plugin/P2P/scheduled model is also resident, loading a
        // third child and later restoring the parent could make the runtime's
        // eviction policy choose that protected model. Refuse before unloading
        // anything.
        let unrelatedProtectedModels = protectedResidentModels.filter {
            $0.caseInsensitiveCompare(modelName) != .orderedSame
        }
        guard unrelatedProtectedModels.isEmpty else {
            throw SubagentError.unavailable(
                "Cannot hand off to local subagent model '\(modelName)' while unrelated "
                    + "non-chat model(s) remain resident: "
                    + unrelatedProtectedModels.sorted().joined(separator: ", ")
                    + ". Use the same resident model, enable a RAM-safe coexistence configuration, "
                    + "or finish the other API/plugin work first."
            )
        }
        return ResidencyPlan(
            shouldUnload: true,
            requiredBytes: requiredBytes,
            ramSafetyEnabled: ramSafetyEnabled,
            maxElapsedSeconds: idleWaitSeconds
        )
    }

    /// Live residency decision for a resolved model name. Reads the installed
    /// bundle (`ModelManager`) + the resident chat models (`ModelRuntime`) and
    /// feeds them to `decidePlan`. A different local model with the handoff
    /// toggle OFF uses scoped parent retention, not the ordinary interactive
    /// eviction path. Memory admission and ownership guards remain separate.
    static func resolve(
        modelName: String,
        config: SubagentConfiguration,
        idleWaitSeconds: Int,
        deniedMessage: String,
        invokingParentModelName: String?
    ) async throws -> SubagentResidencyDecision {
        let installed = ModelManager.findInstalledModel(named: modelName)
        guard let installed else { return SubagentResidencyDecision(isLocal: false, plan: .none) }
        let plan = try await planForLocalTarget(
            modelName: installed.name,
            requiredBytes: ChatResidencyHandoff.estimatedChatModelBytes(named: installed.name),
            config: config,
            idleWaitSeconds: idleWaitSeconds,
            deniedMessage: deniedMessage,
            invokingParentModelName: invokingParentModelName
        )
        return SubagentResidencyDecision(isLocal: true, plan: plan)
    }

    /// Local image bundles use a different registry, but must make the same
    /// exact-parent/protected-resident decision before any unload occurs.
    /// Callers must resolve and validate their installed target first.
    static func planForLocalTarget(
        modelName: String,
        requiredBytes: Int64,
        config: SubagentConfiguration,
        idleWaitSeconds: Int,
        deniedMessage: String,
        invokingParentModelName: String?
    ) async throws -> ResidencyPlan {
        // Compare on the canonical installed-bundle identity, not the raw
        // request string. `ModelRuntime` records resident chat models under
        // their canonical name (e.g. `qwen3.5-4b-optiq-4bit`), while a spawn
        // target is frequently a full repo id (`mlx-community/Qwen3.5-4B-OptiQ-4bit`).
        // Resolving BOTH sides through `findInstalledModel` lets the
        // "same model already resident" check match across those forms — so
        // spawning the SAME model the user is chatting with runs in place
        // instead of needlessly unloading + reloading the identical bundle.
        let residentSummaries = await ModelRuntime.shared.cachedModelSummaries()
        let residentModels: [String] = residentSummaries.map {
            ModelManager.findInstalledModel(named: $0.name)?.name ?? $0.name
        }
        let canonicalParentName = invokingParentModelName.flatMap {
            ModelManager.findInstalledModel(named: $0)?.name ?? $0
        }
        // The parity leg may only reload an INSTALLED local parent; a cloud
        // or unknown parent has nothing to restore.
        let installedParentName = invokingParentModelName.flatMap {
            ModelManager.findInstalledModel(named: $0)?.name
        }
        let parentIsOwned: Bool
        if let invokingParentModelName,
            let inferenceSource = ChatExecutionContext.currentSessionSource?.inferenceSource
        {
            parentIsOwned = await ModelRuntime.shared.isResident(
                named: invokingParentModelName,
                ownedBy: inferenceSource
            )
        } else if let invokingParentModelName {
            parentIsOwned = await ModelRuntime.shared.isChatOwnedResident(
                named: invokingParentModelName
            )
        } else {
            parentIsOwned = false
        }
        let invokingParentModels = residentModels.filter { resident in
            guard parentIsOwned, let canonicalParentName else { return false }
            return resident.caseInsensitiveCompare(canonicalParentName) == .orderedSame
        }
        let invokingParentKeys = Set(invokingParentModels.map { $0.lowercased() })
        let protectedResidentModels = residentModels.filter {
            !invokingParentKeys.contains($0.lowercased())
        }
        return try decidePlan(
            isLocal: true,
            modelName: modelName,
            residentChatModels: invokingParentModels,
            protectedResidentModels: protectedResidentModels,
            handoffEnabled: config.localOrchestratorTextHandoffActive,
            ramSafetyEnabled: config.ramSafetyPreflightEnabled,
            requiredBytes: requiredBytes,
            idleWaitSeconds: idleWaitSeconds,
            deniedMessage: deniedMessage,
            invokingParentModelName: installedParentName
        )
    }

    /// Refresh only residency after scheduling/approval waits. Keep the model
    /// already selected and approved; a removed local bundle must not silently
    /// become a remote route or fall back to a newly configured model.
    static func refreshedPlan(
        for resolved: ResolvedModel,
        invokingParentModelName: String?,
        idleWaitSeconds: Int,
        deniedMessage: String
    ) async throws -> ResidencyPlan {
        guard resolved.isLocal else { return .none }
        guard let installed = ModelManager.findInstalledModel(named: resolved.id ?? resolved.name) else {
            throw SubagentError.unavailable(
                "Local model '\(resolved.name)' is no longer installed."
            )
        }
        let decision = try await resolve(
            modelName: installed.id,
            config: SubagentConfigurationStore.snapshot(),
            idleWaitSeconds: idleWaitSeconds,
            deniedMessage: deniedMessage,
            invokingParentModelName: invokingParentModelName
        )
        guard decision.isLocal else {
            throw SubagentError.unavailable(
                "Local model '\(resolved.name)' became unavailable while the run was waiting."
            )
        }
        return decision.plan
    }

    /// Map a resolved plan onto the host handoff middleware: a real
    /// `ResidencyHandoff` when it unloads, the idle-drain `CoexistenceHandoff`
    /// when both models stay resident, otherwise the passthrough default.
    static func handoff(for plan: ResidencyPlan) -> SubagentHandoff {
        if plan.shouldUnload { return ResidencyHandoff.production { _ in plan } }
        if plan.coexists {
            return CoexistenceHandoff.production(plan: plan)
        }
        return PassthroughHandoff()
    }

    /// Map a resolved plan onto the process-wide admission class
    /// (`SubagentAdmission`): a plan that unloads resident models owns the GPU
    /// exclusively; a coexistence run ALSO admits exclusively (two resident
    /// graphs must never both generate — the run may share residency but not
    /// the GPU's producer slot); a local run without a swap shares with other
    /// in-place runs; remote never contends.
    static func admissionClass(isLocal: Bool, plan: ResidencyPlan) -> SubagentAdmissionClass {
        if plan.shouldUnload || plan.coexists { return .localExclusive }
        return isLocal ? .localInPlace : .remote
    }
}
