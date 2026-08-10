//
//  SubagentModelResolution.swift
//  OsaurusCore — Subagent framework
//
//  The one model-resolution path the chat-driven subagent kinds (spawn,
//  computer_use) share. Each kind previously repeated the same
//  three steps inline: look up the per-agent model override, fall back to the
//  kind's default model source, then run the live `SubagentResidency` decision
//  and stash the plan for `makeHandoff()`. This folds that into one precedence
//  (`pickModel`) + one availability gate (`availableOverride`) + one live
//  `resolve`, so a new chat-driven kind gets the whole behaviour for free and
//  the three kinds can never drift on precedence, fail-closed override
//  availability, or
//  the eval-bypasses-residency invariant.
//
//  Image is deliberately NOT a client: it owns its own model system
//  (`imageGenerationModelId` / `imageEditModelId`, `effectiveImageModel`, the
//  gen/edit split + readiness, coordinator-owned residency) and sets
//  `SubagentCapability.supportsModelOverride = false`. Every kind that DOES set
//  `supportsModelOverride = true` resolves through here.
//

import Foundation

/// The shared model-resolution layer for chat-driven subagent kinds. Stateless
/// and split into a pure precedence step (`pickModel`), a `@MainActor`
/// availability gate (`availableOverride`), and a live `resolve` wrapper that
/// folds in `SubagentResidency`. The pure pieces unit-test with no GPU / no
/// MainActor.
enum SubagentModelResolution {
    /// The resolved run model plus the residency decision its `makeHandoff()`
    /// will run. Bundled so a kind stores one value and returns one model.
    struct Resolved: Sendable {
        let model: String
        /// Canonical full installed id for a local bundle. The user-facing
        /// `model` string may be a short alias, but admission and batching must
        /// never collapse two organizations that publish the same basename.
        let installedModelID: String?
        let decision: SubagentResidencyDecision

        init(
            model: String,
            installedModelID: String? = nil,
            decision: SubagentResidencyDecision
        ) {
            self.model = model
            self.installedModelID = installedModelID
            self.decision = decision
        }
    }

    /// Pure model precedence: the eval seam (forced run model) wins, then an
    /// AVAILABLE per-agent override, then the kind's default model source.
    /// Empty / whitespace-only entries are treated as absent so a blank stored
    /// value transparently inherits. No dependencies, so the precedence is
    /// unit-testable on its own.
    static func pickModel(
        evalModel: String?,
        availableOverride: String?,
        defaultModel: String?
    ) -> String? {
        trimmedNonEmpty(evalModel)
            ?? trimmedNonEmpty(availableOverride)
            ?? trimmedNonEmpty(defaultModel)
    }

    /// Trim a model id and treat empty / whitespace-only as absent (`nil`), so a
    /// blank stored value transparently inherits at every precedence slot.
    private static func trimmedNonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty
        else { return nil }
        return trimmed
    }

    /// The stored override id IF it is still usable, else `nil`. A caller with
    /// a non-empty configured override must treat nil as unavailable rather
    /// than silently running the kind default: that would execute an
    /// unconfigured model. Local installs are
    /// authoritative (the picker cache may not list every bundle); a remote id
    /// is checked against `ModelPickerItemCache`, which mirrors connected
    /// providers. A cold cache can't disprove availability, so the id is
    /// trusted rather than silently dropped.
    @MainActor
    static func availableOverride(_ id: String?) -> String? {
        guard let trimmed = trimmedNonEmpty(id) else { return nil }
        if ModelManager.findInstalledModel(named: trimmed) != nil { return trimmed }
        if let remote = RemoteProviderManager.shared.connectedSpawnModelTarget(
            forStoredId: trimmed
        ) {
            return remote.id
        }
        // A canonical spawn-only remote id must always be backed by a live
        // connected provider/service. Do not let a cold picker cache turn a
        // disconnected or removed UUID target into a trusted opaque model id.
        if SpawnRemoteModelIdentity.parse(trimmed) != nil { return nil }
        guard ModelPickerItemCache.shared.isLoaded else { return trimmed }
        return ModelPickerItemCache.shared.items.contains { $0.id == trimmed } ? trimmed : nil
    }

    /// Live resolution for a chat-driven kind.
    ///
    /// - Eval seam: when `evalModel` is set the run model is forced and the
    ///   residency decision is the passthrough `(isLocal: false, plan: .none)` —
    ///   the uniform eval-bypasses-residency invariant, so a deterministic lane
    ///   never depends on live GPU residency.
    /// - Otherwise: resolves the launching agent's `settings`, reads the
    ///   per-agent `effectiveSubagentModel` override, requires it to pass
    ///   `availableOverride` when configured, otherwise uses `defaultModel()`,
    ///   then runs the
    ///   shared `SubagentResidency.resolve` (reject-before-evict).
    ///
    /// `agentId` is the launching agent whose override map + settings are read
    /// (spawn/computer_use pass `scope.agentId`). `defaultModel` is the kind's
    /// default model source, evaluated on the main actor only when no override
    /// is configured. An unavailable configured override fails closed.
    ///
    /// `requestedModel` is an EXPLICIT run-model target (the `spawn_model`
    /// tool's `model` argument, including each `spawn_batch` model job). Unlike
    /// `evalModel` it does NOT bypass residency. It ranks above the per-agent
    /// override and kind default, but its persisted allow-list membership is
    /// not treated as proof of current availability: the target must still be
    /// Foundation, an installed local model, or a model advertised by a
    /// currently connected provider before the residency decision can run.
    static func resolve(
        capabilityId: String,
        agentId: UUID?,
        evalModel: String?,
        requestedModel: String? = nil,
        invokingParentModelName: String? = nil,
        idleWaitSeconds: Int,
        deniedMessage: String,
        unavailableMessage: String,
        defaultModel: @escaping @Sendable @MainActor () -> String?
    ) async throws -> Resolved {
        // Eval seam: force the model, keep residency passthrough.
        if let forced = trimmedNonEmpty(evalModel) {
            return Resolved(
                model: forced,
                decision: SubagentResidencyDecision(isLocal: false, plan: .none)
            )
        }

        let config = SubagentConfigurationStore.snapshot()
        let isDefault = agentId == Agent.defaultId
        let requested = await MainActor.run {
            currentRequestedTarget(requestedModel)
        }
        if trimmedNonEmpty(requestedModel) != nil, requested == nil {
            throw SubagentError.unavailable(unavailableMessage)
        }
        let model: String? = try await MainActor.run {
            // Explicit target (spawn_model) wins over the override/default, but
            // only after current availability was proven above. It still flows
            // into the residency decision below (not a bypass).
            if let requested { return requested }
            let settings = agentId.flatMap { AgentManager.shared.agent(for: $0)?.settings }
            let configuredOverride = SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: capabilityId,
                isDefault: isDefault,
                config: config,
                settings: settings
            )
            if let configuredOverride = trimmedNonEmpty(configuredOverride) {
                guard let available = availableOverride(configuredOverride) else {
                    throw SubagentError.unavailable(unavailableMessage)
                }
                return available
            }
            return pickModel(
                evalModel: nil,
                availableOverride: nil,
                defaultModel: defaultModel()
            )
        }
        guard let model, !model.isEmpty else {
            throw SubagentError.unavailable(unavailableMessage)
        }

        let decision = try await SubagentResidency.resolve(
            modelName: model,
            config: config,
            idleWaitSeconds: idleWaitSeconds,
            deniedMessage: deniedMessage,
            invokingParentModelName: invokingParentModelName
        )
        let installedModelID =
            decision.isLocal ? ModelManager.findInstalledModel(named: model)?.id : nil
        return Resolved(
            model: model,
            installedModelID: installedModelID,
            decision: decision
        )
    }

    /// Normalize and validate one explicit model-only spawn target against
    /// current runtime truth. This is intentionally independent of the picker
    /// cache: a cache row can be cold or stale, while local installation state
    /// and the connected provider catalog are the owning sources used during
    /// preparation. Both `spawn_model` and `spawn_batch` reuse this check via
    /// `resolve`, before admission or any model unload/load can occur.
    @MainActor
    static func currentRequestedTarget(_ id: String?) -> String? {
        guard let trimmed = trimmedNonEmpty(id) else { return nil }
        if trimmed == ModelPickerItem.foundation().id {
            return AppConfiguration.shared.foundationModelAvailable ? trimmed : nil
        }
        if ModelManager.findInstalledModel(named: trimmed) != nil {
            return trimmed
        }
        if let remote = RemoteProviderManager.shared.connectedSpawnModelTarget(
            forStoredId: trimmed
        ) {
            return remote.id
        }
        return nil
    }
}
