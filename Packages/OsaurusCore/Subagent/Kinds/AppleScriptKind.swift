//
//  AppleScriptKind.swift
//  OsaurusCore — Subagent framework
//
//  The AppleScript subagent kind that serves the `applescript` tool. It
//  resolves an INSTALLED on-device AppleScript model (a dedicated bundle, like
//  `image`), drives `AppleScriptLoop` to generate + run AppleScript, and hands
//  back a compact summary on the shared `SubagentSession` host.
//
//  `modelSource = .dedicatedConfigured` and `supportsModelOverride = false`:
//  AppleScript owns its own model system (the curated `AppleScriptModelCatalog`,
//  a per-agent / global `appleScriptModelId`, and a first-installed fallback),
//  so it is NOT a `SubagentModelResolution` client and AgentsView renders its
//  own picker instead of the shared override row — exactly the divergence
//  `image` established.
//
//  Residency: the AppleScript model is ALWAYS a different bundle than the
//  resident chat model, so when a chat model is loaded this kind must unload it
//  for the run (single-GPU residency) and reload after. It forces that handoff
//  independent of the global "Local Orchestrator Handoff" toggle (which exists
//  for the chat-driven kinds), because requiring an unrelated toggle would make
//  the feature unusable. The per-script consent surface is the execution-mode
//  gate inside the loop (confirm-each / auto-run-with-warning), so the host
//  permission is `.allow`.
//

import Foundation

final class AppleScriptKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapabilityRegistry.appleScript

    private let task: String
    private let limits: RunLimits

    /// Resolved in `resolveModel`, consumed by `run`. Captured once so a mid-run
    /// settings edit can't change the rules under the running loop.
    private var executionMode: AppleScriptExecutionMode = .default
    /// Residency plan resolved up front (reject-before-evict), run by
    /// `makeHandoff()`. `.none` when nothing else is resident.
    private var residencyPlan: ResidencyPlan = .none

    /// Idle-wait budget (seconds) for the residency unload to wait for chat to
    /// go idle before giving up. Bounds only the pre-unload wait; the run itself
    /// is step-capped via `RunLimits`.
    private static let residencyIdleWaitSeconds = 120

    init(task: String, limits: RunLimits) {
        self.task = task
        self.limits = limits
    }

    var feedTitle: String { task }

    // MARK: - Model resolution (reject-before-evict)

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let config = SubagentConfigurationStore.snapshot()
        let isDefault = scope.agentId == Agent.defaultId
        let settings = await MainActor.run {
            AgentManager.shared.agent(for: scope.agentId)?.settings
        }

        // Per-agent enable (no global master switch): Default / main chat → its
        // own AppleScript switch; a custom agent → its own `appleScriptEnabled`.
        let available = SubagentToolVisibility.appleScriptAvailable(
            isDefault: isDefault,
            config: config,
            perAgentEnabled: settings?.appleScriptEnabled ?? false
        )
        guard available else {
            throw SubagentError.denied("AppleScript is not enabled for this agent.")
        }

        // Dedicated model: the configured per-agent / global id, else the first
        // installed catalog model. `nil` → none installed → fail cleanly.
        let preferred = SubagentToolVisibility.effectiveAppleScriptModel(
            isDefault: isDefault,
            config: config,
            settings: settings
        )
        guard let modelId = AppleScriptModelCatalog.resolveInstalledModelId(preferred: preferred)
        else {
            throw SubagentError.unavailable(
                "No AppleScript model is installed. Download one in Settings → Computer Use → Models."
            )
        }

        self.executionMode = SubagentToolVisibility.effectiveAppleScriptExecutionMode(
            isDefault: isDefault,
            config: config,
            settings: settings
        )

        // Single-GPU residency: the AppleScript bundle differs from any resident
        // chat model, so force the handoff (independent of the global toggle).
        let decision = try await SubagentResidency.resolve(
            modelName: modelId,
            config: config,
            idleWaitSeconds: Self.residencyIdleWaitSeconds,
            deniedMessage:
                "AppleScript needs to load its own model, which requires unloading the chat model to "
                + "make room.",
            handoffEnabledOverride: true
        )
        self.residencyPlan = decision.plan
        return ResolvedModel(name: modelId, id: modelId, isLocal: decision.isLocal)
    }

    func makeHandoff() -> SubagentHandoff {
        SubagentResidency.handoff(for: residencyPlan)
    }

    /// `.allow` at the host level: the consent surface is the per-script
    /// execution-mode gate inside `run` (confirm-each / auto-run-with-warning),
    /// not a per-call approval card.
    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        .allow
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        let toolCallId = scope.toolCallId
        // The confirm overlay drains off `ComputerUsePromptQueue` (shared with
        // Computer Use); clear any pending prompt for this run when it ends.
        defer {
            Task { @MainActor in
                ComputerUsePromptQueue.shared.cancelAll(forToolCallId: toolCallId)
            }
        }

        let result = await AppleScriptLoop.run(
            task: task,
            modelId: resolved.name,
            feed: feed,
            interrupt: interrupt,
            executionMode: executionMode,
            confirm: { preview in
                await ComputerUsePromptQueue.shared.requestConfirmation(
                    preview,
                    toolCallId: toolCallId
                )
            },
            limits: limits,
            sessionId: scope.sessionId
        )
        return try Self.mapOutcome(result, model: resolved.name)
    }

    /// Map a finished `AppleScriptLoop` run onto the shared subagent result
    /// contract: `done` → a compact success payload; `interrupted` → a
    /// `user_denied` envelope; every other non-completion → a non-retryable
    /// `execution_error` carrying the loop's own reason.
    private static func mapOutcome(
        _ result: AppleScriptRunResult,
        model: String
    ) throws -> SubagentResult {
        switch result.outcome {
        case .done(let summary):
            var payload: [String: Any] = [
                "kind": "applescript",
                "model": model,
                "summary": summary,
                "scripts_run": result.scriptsExecuted,
            ]
            if let output = result.lastOutput, !output.isEmpty {
                payload["output"] = output
            }
            return SubagentResult(payload: payload, summary: summary)
        case .interrupted:
            throw SubagentError.userDenied("AppleScript was stopped by the user.")
        case .stepCapReached, .failed:
            throw SubagentError.executionFailed(message: result.outcome.summary, retryable: false)
        }
    }
}
