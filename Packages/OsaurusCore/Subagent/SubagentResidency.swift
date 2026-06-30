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
    /// Pure residency decision — no `ModelRuntime` / `ModelManager`, so the
    /// control flow (remote ⇒ none, same ⇒ none, different-local + handoff-off ⇒
    /// denied, different-local + handoff-on ⇒ unload) is unit-testable with no
    /// GPU. `residentChatModels` is the live set of resident chat-model names;
    /// the caller resolves it (empty when the model isn't local).
    static func decidePlan(
        isLocal: Bool,
        modelName: String,
        residentChatModels: [String],
        handoffEnabled: Bool,
        ramSafetyEnabled: Bool,
        requiredBytes: Int64,
        idleWaitSeconds: Int,
        deniedMessage: String
    ) throws -> ResidencyPlan {
        // A remote/router model never touches local GPU residency.
        guard isLocal else { return .none }
        // Only a DIFFERENT resident chat model forces a swap; the same model
        // already resident is reused in place.
        let otherResidentModels = residentChatModels.filter {
            $0.caseInsensitiveCompare(modelName) != .orderedSame
        }
        guard !otherResidentModels.isEmpty else { return .none }
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
        handoffEnabledOverride: Bool? = nil
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
        let residentChatModels: [String] =
            isLocal
            ? await ModelRuntime.shared.cachedModelSummaries().map {
                ModelManager.findInstalledModel(named: $0.name)?.name ?? $0.name
            }
            : []
        let plan = try decidePlan(
            isLocal: isLocal,
            modelName: canonicalName,
            residentChatModels: residentChatModels,
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
            deniedMessage: deniedMessage
        )
        return SubagentResidencyDecision(isLocal: isLocal, plan: plan)
    }

    /// Map a resolved plan onto the host handoff middleware: a real
    /// `ResidencyHandoff` when it unloads, otherwise the passthrough default.
    static func handoff(for plan: ResidencyPlan) -> SubagentHandoff {
        plan.shouldUnload ? ResidencyHandoff.production { _ in plan } : PassthroughHandoff()
    }
}
