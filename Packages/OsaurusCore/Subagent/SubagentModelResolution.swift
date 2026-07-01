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
//  the three kinds can never drift on precedence, the availability fallback, or
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
        let decision: SubagentResidencyDecision
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

    /// The stored override id IF it is still usable, else `nil` so the caller
    /// falls back to the kind default instead of hard-failing on a model that
    /// was deleted or whose provider disconnected. Local installs are
    /// authoritative (the picker cache may not list every bundle); a remote id
    /// is checked against `ModelPickerItemCache`, which mirrors connected
    /// providers. A cold cache can't disprove availability, so the id is
    /// trusted rather than silently dropped.
    @MainActor
    static func availableOverride(_ id: String?) -> String? {
        guard let trimmed = trimmedNonEmpty(id) else { return nil }
        if ModelManager.findInstalledModel(named: trimmed) != nil { return trimmed }
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
    ///   per-agent `effectiveSubagentModel` override, drops it through
    ///   `availableOverride`, falls back to `defaultModel()`, then runs the
    ///   shared `SubagentResidency.resolve` (reject-before-evict).
    ///
    /// `agentId` is the launching agent whose override map + settings are read
    /// (spawn/computer_use pass `scope.agentId`). `defaultModel` is the kind's
    /// default model source, evaluated on the
    /// main actor only when no usable override is present.
    ///
    /// `requestedModel` is an EXPLICIT run-model target the caller resolved
    /// itself (the `spawn_model` tool's `model` argument). Unlike `evalModel` it
    /// does NOT bypass residency — it is used as-is (trusted; the kind already
    /// pool-gated it) and still runs the live `SubagentResidency` decision so a
    /// local target evicts the resident chat model and a remote one does not. It
    /// ranks above the per-agent override and the kind default, and deliberately
    /// skips the `availableOverride` cache check so an explicit target isn't
    /// silently swapped for a default — an unavailable id surfaces a real load
    /// error from residency instead.
    static func resolve(
        capabilityId: String,
        agentId: UUID?,
        evalModel: String?,
        requestedModel: String? = nil,
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
        let model: String? = await MainActor.run {
            // Explicit target (spawn_model) wins over the override/default, but
            // still flows into the residency decision below (not a bypass).
            if let requested = trimmedNonEmpty(requestedModel) { return requested }
            let settings = agentId.flatMap { AgentManager.shared.agent(for: $0)?.settings }
            let override = SubagentToolVisibility.effectiveSubagentModel(
                capabilityId: capabilityId,
                isDefault: isDefault,
                config: config,
                settings: settings
            )
            return pickModel(
                evalModel: nil,
                availableOverride: availableOverride(override),
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
            deniedMessage: deniedMessage
        )
        return Resolved(model: model, decision: decision)
    }
}
