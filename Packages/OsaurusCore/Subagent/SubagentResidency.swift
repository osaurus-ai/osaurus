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

/// Live RAM numbers for the coexistence gate in `decidePlan`, resolved by the
/// `resolve` wrapper so the decision itself stays a pure function. `.disabled`
/// (allowed == false) preserves the single-residency default.
struct SubagentCoexistence: Sendable {
    /// User opt-in AND flexible eviction policy. Strict policy must pass
    /// false: the runtime itself strict-evicts any other resident model on
    /// load, which would silently evict the orchestrator with NO restore lease.
    var allowed: Bool
    /// Reclaimable physical memory right now (free + inactive + purgeable),
    /// WITHOUT counting resident chat models — they stay loaded.
    var availableBytes: Int64
    /// Sum of resident chat-model weight bytes (they remain resident).
    var residentBytes: Int64
    /// The runtime's flexible-mode resident-weights soft cap
    /// (`ModelRuntime.flexibleResidentBudgetBytes`). Loading past it triggers
    /// the runtime's own budget eviction — which would evict the orchestrator
    /// without a restore lease — so the gate must stay under it. `0` = no cap.
    var flexibleBudgetBytes: Int64
    /// Result of applying the exact bundle-aware Memory Safety request estimate
    /// used by `ModelRuntime.loadContainer`. Coexistence must not approve a
    /// target that the loader will immediately reject under the user's active
    /// Memory Safety profile or explicit budget.
    var memorySafetyAllowsTargetLoad: Bool = true

    static let disabled = SubagentCoexistence(
        allowed: false,
        availableBytes: 0,
        residentBytes: 0,
        flexibleBudgetBytes: 0
    )

    /// Same footprint model as `ChatResidencyHandoff.memoryPreflight`: weights
    /// inflate ~1.3x once resident (KV + activations + framework overhead)…
    static let residencyInflation = 1.3
    /// …plus fixed headroom kept for the OS/app.
    static let headroomBytes: Int64 = 3 * 1024 * 1024 * 1024

    /// Whether a subagent model of `requiredBytes` (on-disk weights) fits
    /// alongside the resident models. Unknown size (`<= 0`) never fits — the
    /// gate must be able to prove the projection, not assume it.
    func fits(
        requiredBytes: Int64,
        targetAlreadyResident: Bool = false
    ) -> Bool {
        guard allowed, requiredBytes > 0 else { return false }
        // The normal loader returns an already-resident holder before it
        // evaluates a cold-load request estimate. Mirror that ownership
        // boundary here: tightening Memory Safety may refuse a new load, but
        // must not make safe reuse of an existing protected target disappear.
        guard memorySafetyAllowsTargetLoad || targetAlreadyResident else {
            return false
        }
        // `residentBytes` already includes an existing protected target. Reuse
        // therefore needs only the non-weight working-set allowance (the 30%
        // portion of the same conservative estimate), not a second copy of
        // its weights. The batch planner separately charges each child's
        // architecture-aware KV/SSM/activation state.
        let weightMultiplier =
            targetAlreadyResident ? Self.residencyInflation - 1 : Self.residencyInflation
        let needed =
            Int64(Double(requiredBytes) * weightMultiplier)
            + Self.headroomBytes
        guard availableBytes >= needed else { return false }
        // Mirror the runtime's flexible-budget eviction check (raw weights,
        // uninflated — same terms `unloadForFlexibleResidentBudget` compares).
        let incrementalWeights = targetAlreadyResident ? 0 : requiredBytes
        if flexibleBudgetBytes > 0,
            residentBytes + incrementalWeights > flexibleBudgetBytes
        {
            return false
        }
        return true
    }
}

enum SubagentResidency {
    /// Pure residency decision — no `ModelRuntime` / `ModelManager`, so the
    /// control flow (remote ⇒ none, same ⇒ none, different-local + handoff-off ⇒
    /// denied, different-local + coexistence-fits ⇒ coexist, different-local +
    /// handoff-on ⇒ unload) is unit-testable with no GPU. `residentChatModels`
    /// is the live set of resident chat-model names; the caller resolves it
    /// (empty when the model isn't local).
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
        coexistence: SubagentCoexistence = .disabled
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
            return ResidencyPlan(
                shouldUnload: false,
                requiredBytes: requiredBytes,
                ramSafetyEnabled: ramSafetyEnabled,
                maxElapsedSeconds: idleWaitSeconds
            )
        }
        // RAM-aware coexistence: both models fit (flexible policy, projection
        // proven) → skip the 10–60s unload+reload round-trip and run alongside.
        // Checked before the handoff-enabled gate on purpose: coexistence does
        // not unload the orchestrator, which is exactly what that toggle
        // protects. Tight RAM or unknown size falls through to the handoff.
        let targetAlreadyResident =
            residentChatModels.contains {
                $0.caseInsensitiveCompare(modelName) == .orderedSame
            }
            || protectedResidentModels.contains {
                $0.caseInsensitiveCompare(modelName) == .orderedSame
            }
        if coexistence.fits(
            requiredBytes: requiredBytes,
            targetAlreadyResident: targetAlreadyResident
        ) {
            return ResidencyPlan(
                shouldUnload: false,
                requiredBytes: requiredBytes,
                ramSafetyEnabled: ramSafetyEnabled,
                maxElapsedSeconds: idleWaitSeconds,
                coexists: true
            )
        }
        // Reusing a protected target is safe only when the invoking parent can
        // coexist with it. If coexistence did not pass above, unloading the
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
        // Reject BEFORE evicting: if the handoff is disabled, fail cleanly so
        // nothing is unloaded.
        guard handoffEnabled else { throw SubagentError.denied(deniedMessage) }
        return ResidencyPlan(
            shouldUnload: true,
            requiredBytes: requiredBytes,
            ramSafetyEnabled: ramSafetyEnabled,
            maxElapsedSeconds: idleWaitSeconds
        )
    }

    /// Live residency decision for a resolved model name. Reads the installed
    /// bundle (`ModelManager`) + the resident chat models (`ModelRuntime`) and
    /// feeds them to `decidePlan`. Throws `SubagentError.denied` when a
    /// different local model would require the handoff but it is disabled.
    static func resolve(
        modelName: String,
        config: SubagentConfiguration,
        idleWaitSeconds: Int,
        deniedMessage: String,
        handoffEnabledOverride: Bool? = nil,
        invokingParentModelName: String? = nil
    ) async throws -> SubagentResidencyDecision {
        let installed = ModelManager.findInstalledModel(named: modelName)
        let isLocal = installed != nil
        // Compare on the canonical installed-bundle identity, not the raw
        // request string. `ModelRuntime` records resident chat models under
        // their canonical name (e.g. `qwen3.5-4b-optiq-4bit`), while a spawn
        // target is frequently a full repo id (`mlx-community/Qwen3.5-4B-OptiQ-4bit`).
        // Resolving BOTH sides through `findInstalledModel` lets the
        // "same model already resident" check match across those forms — so
        // spawning the SAME model the user is chatting with runs in place
        // instead of needlessly unloading + reloading the identical bundle.
        let canonicalName = installed?.name ?? modelName
        let residentSummaries =
            isLocal ? await ModelRuntime.shared.cachedModelSummaries() : []
        let residentModels: [String] = residentSummaries.map {
            ModelManager.findInstalledModel(named: $0.name)?.name ?? $0.name
        }
        let canonicalParentName = invokingParentModelName.flatMap {
            ModelManager.findInstalledModel(named: $0)?.name ?? $0
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
        // Coexistence gate inputs (live numbers; the decision itself is pure).
        // Only meaningful when the user opted in AND the server eviction policy
        // is Flexible — under Strict the runtime itself evicts any other
        // resident model on load, which would strand the orchestrator with no
        // restore lease, so Strict always keeps the single-residency handoff.
        let coexistence: SubagentCoexistence
        if isLocal, config.subagentCoexistenceEnabled {
            let policy = await MainActor.run {
                ServerConfigurationStore.load()?.modelEvictionPolicy ?? .strictSingleModel
            }
            let memorySafetyAllowsTargetLoad =
                await ModelRuntime.shared.subagentCoexistenceMemorySafetyAllowsLoad(
                    for: canonicalName
                )
            coexistence = SubagentCoexistence(
                allowed: policy == .manualMultiModel,
                availableBytes: ChatResidencyHandoff.availableMemoryBytes(),
                residentBytes: residentSummaries.reduce(Int64(0)) { $0 + $1.bytes },
                flexibleBudgetBytes: ModelRuntime.flexibleResidentBudgetBytes(),
                memorySafetyAllowsTargetLoad: memorySafetyAllowsTargetLoad
            )
        } else {
            coexistence = .disabled
        }
        let plan = try decidePlan(
            isLocal: isLocal,
            modelName: canonicalName,
            residentChatModels: invokingParentModels,
            protectedResidentModels: protectedResidentModels,
            // A dedicated-model kind (AppleScript) always loads a DIFFERENT
            // bundle than the chat model, so requiring the global "Local
            // Orchestrator Handoff" toggle would make it unusable; such kinds
            // pass `true` to force the handoff. Chat-driven kinds (spawn,
            // computer_use) pass `nil` and honor the user's global toggle.
            handoffEnabled: handoffEnabledOverride ?? config.localOrchestratorTextHandoffActive,
            ramSafetyEnabled: config.ramSafetyPreflightEnabled,
            requiredBytes: isLocal
                ? ChatResidencyHandoff.estimatedChatModelBytes(named: modelName) : 0,
            idleWaitSeconds: idleWaitSeconds,
            deniedMessage: deniedMessage,
            coexistence: coexistence
        )
        return SubagentResidencyDecision(isLocal: isLocal, plan: plan)
    }

    /// Map a resolved plan onto the host handoff middleware: a real
    /// `ResidencyHandoff` when it unloads, the idle-drain `CoexistenceHandoff`
    /// when both models stay resident, otherwise the passthrough default.
    static func handoff(for plan: ResidencyPlan) -> SubagentHandoff {
        if plan.shouldUnload { return ResidencyHandoff.production { _ in plan } }
        if plan.coexists {
            return CoexistenceHandoff.production(maxElapsedSeconds: plan.maxElapsedSeconds)
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
