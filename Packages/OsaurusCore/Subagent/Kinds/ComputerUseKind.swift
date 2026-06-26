//
//  ComputerUseKind.swift
//  OsaurusCore — Subagent framework
//
//  The desktop-automation sub-agent kind that serves `computer_use`. It runs
//  the unchanged `ComputerUseLoop` (perceive → decide → gate → act → verify)
//  on the shared `SubagentSession` host so the recursion guard, the live
//  `SubagentFeed`, the interrupt token, and the compact-result contract are
//  shared with spawn / image / sandbox_reduce.
//
//  What stays computer-use specific (NOT generalized):
//    - The per-action `ComputerUseGate` + the `ComputerUsePromptQueue` confirm
//      / cloud-vision consent overlay. The host permission is `.allow` — the
//      real consent surface is the gate inside `run`, exactly as before.
//    - `modelSource = .inheritsParent`: the loop drives the SAME model as the
//      parent chat (no residency eviction; `makeHandoff()` stays passthrough).
//

import Foundation

final class ComputerUseKind: SubagentKind, @unchecked Sendable {
    let capability = SubagentCapabilityRegistry.computerUse

    private let goal: String
    private let limits: RunLimits

    /// Snapshot resolved on the main actor in `resolveModel`, consumed by
    /// `run`. Captured once so a mid-run settings edit can't change the rules
    /// under the running loop.
    private struct RunConfig {
        let ceiling: AutonomyCeiling?
        let policy: AutonomyPolicy
        let vision: VisionContext
        let policySummary: String
    }
    private var config: RunConfig?

    init(goal: String, limits: RunLimits) {
        self.goal = goal
        self.limits = limits
    }

    var feedTitle: String { goal }

    func resolveModel(_ scope: SubagentScope) async throws -> ResolvedModel {
        let agentId = scope.agentId
        // Resolve everything that lives on the main actor in one hop: the model,
        // the agent's autonomy ceiling, a snapshot of the user policy, and the
        // vision context (image support + local-vs-cloud posture + cloud-vision
        // consent).
        let snapshot = await MainActor.run {
            () -> (model: String?, ceiling: AutonomyCeiling?, policy: AutonomyPolicy, vision: VisionContext) in
            let model = AgentManager.shared.effectiveModel(for: agentId)
            let ceiling = AgentManager.shared.agent(for: agentId)?.settings.computerUseCeiling
            let policy = ComputerUsePolicyStore.load()
            let vision: VisionContext
            if let model, !model.isEmpty {
                vision = VisionContext(
                    modelAcceptsImages: ComputerUseTool.modelAcceptsImages(model),
                    modelIsLocal: ModelManager.findInstalledModel(named: model) != nil,
                    cloudConsent: CloudVisionConsent.shared.isGranted,
                    cloudScrubMode: CloudVisionConsent.shared.scrubMode
                )
            } else {
                vision = .none
            }
            return (model, ceiling, policy, vision)
        }
        guard let modelId = snapshot.model, !modelId.isEmpty else {
            throw SubagentError.unavailable(
                "No model is selected for this agent, so Computer Use can't run. Pick a model first."
            )
        }
        self.config = RunConfig(
            ceiling: snapshot.ceiling,
            policy: snapshot.policy,
            vision: snapshot.vision,
            policySummary: ComputerUseTool.policySummary(
                policy: snapshot.policy,
                ceiling: snapshot.ceiling
            )
        )
        // Same-model kind: residency is irrelevant (no handoff), so `isLocal`
        // is not consulted.
        return ResolvedModel(name: modelId, id: nil, isLocal: false)
    }

    /// `.allow` at the host level: the consent surface is the per-action gate
    /// (`ComputerUseGate` + confirm overlay) wired inside `run`, not a per-call
    /// approval card. Accessibility preflight stays on the tool's
    /// `PermissionedTool` gate before the host is even reached.
    func permission(_ scope: SubagentScope, _ resolved: ResolvedModel) async -> SubagentDecision {
        .allow
    }

    func run(
        _ scope: SubagentScope,
        _ resolved: ResolvedModel,
        feed: SubagentFeed,
        interrupt: InterruptToken
    ) async throws -> SubagentResult {
        guard let config else {
            throw SubagentError.unavailable("Computer Use could not resolve its run configuration.")
        }
        let toolCallId = scope.toolCallId
        // The confirm/consent overlay drains off `ComputerUsePromptQueue`; clear
        // any pending prompts for this run when it ends (mirrors the old tool's
        // defer). The host only unregisters the feed + interrupt.
        defer {
            Task { @MainActor in
                ComputerUsePromptQueue.shared.cancelAll(forToolCallId: toolCallId)
            }
        }

        let result = await ComputerUseLoop.run(
            goal: goal,
            modelId: resolved.name,
            driver: NativeMacDriver(),
            gate: ComputerUseGate(policy: config.policy, ceiling: config.ceiling),
            feed: feed,
            interrupt: interrupt,
            confirm: { preview in
                await ComputerUsePromptQueue.shared.requestConfirmation(
                    preview,
                    toolCallId: toolCallId
                )
            },
            requestCloudVisionConsent: {
                await ComputerUsePromptQueue.shared.requestCloudVisionConsent(toolCallId: toolCallId)
            },
            limits: limits,
            policySummary: config.policySummary,
            vision: config.vision,
            sessionId: scope.sessionId
        )

        let outcome = result.outcome
        let metrics = result.metrics
        await MainActor.run {
            FeatureTelemetry.computerUseRun(metrics, outcome: ComputerUseTool.outcomeToken(outcome))
        }

        switch outcome {
        case .done(let summary):
            return SubagentResult(
                payload: [
                    "kind": "computer_use",
                    "model": resolved.name,
                    "summary": summary,
                    "steps": metrics.steps,
                ] as [String: Any],
                summary: summary
            )
        case .interrupted:
            throw SubagentError.userDenied("Computer Use was stopped by the user.")
        case .gaveUp, .deadEnd, .stepCapReached, .failed:
            // A legitimate non-completion — not a tool malfunction. Surface the
            // reason so the parent model can pivot, but don't invite a blind retry.
            throw SubagentError.executionFailed(message: outcome.summary, retryable: false)
        }
    }
}
